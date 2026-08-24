//! Read-only rtnetlink: link/address observation for GET /network and WAN
//! failover events (docs/07 §2; phase-3 decision: netlink is OBSERVATION
//! ONLY — route policy is expressed via metrics in the rendered
//! dhcpcd.conf, never by rtnetlink surgery from cragd).
//!
//! Two layers:
//!  - pure parsers over raw netlink bytes (parseLinkDump/parseAddrDump),
//!    unit-tested against hand-built dump payloads;
//!  - a live layer: dump() (RTM_GETLINK + RTM_GETADDR request/response)
//!    and Monitor (a thread on RTMGRP_LINK|RTMGRP_IPV4_IFADDR|
//!    RTMGRP_IPV6_IFADDR publishing carrier/addr events).
//!
//! Structs and constants are declared locally from the stable kernel ABI
//! (linux/netlink.h, linux/rtnetlink.h, linux/if_link.h) rather than
//! chasing std.os.linux coverage across Zig releases.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Error = error{
    /// Malformed/truncated netlink payload.
    Truncated,
    /// Socket-level failure on the live paths.
    Netlink,
    OutOfMemory,
};

// ---- kernel ABI (linux/netlink.h, linux/rtnetlink.h) ------------------------

pub const NLMSG_DONE: u16 = 3;
pub const NLMSG_ERROR: u16 = 2;
pub const RTM_NEWLINK: u16 = 16;
pub const RTM_DELLINK: u16 = 17;
pub const RTM_GETLINK: u16 = 18;
pub const RTM_NEWADDR: u16 = 20;
pub const RTM_DELADDR: u16 = 21;
pub const RTM_GETADDR: u16 = 22;

const NLM_F_REQUEST: u16 = 0x01;
const NLM_F_DUMP: u16 = 0x300; // NLM_F_ROOT | NLM_F_MATCH

// rtnetlink multicast groups (bitmask form for sockaddr_nl.groups).
pub const RTMGRP_LINK: u32 = 0x1;
pub const RTMGRP_IPV4_IFADDR: u32 = 0x10;
pub const RTMGRP_IPV6_IFADDR: u32 = 0x100;

// IFLA_* attributes (linux/if_link.h).
const IFLA_ADDRESS: u16 = 1;
const IFLA_IFNAME: u16 = 3;
const IFLA_CARRIER: u16 = 33;

// IFA_* attributes (linux/if_addr.h).
const IFA_ADDRESS: u16 = 1;
const IFA_LOCAL: u16 = 2;

// net_device flags (linux/if.h).
const IFF_UP: u32 = 0x1;
const IFF_RUNNING: u32 = 0x40;
const IFF_LOWER_UP: u32 = 0x10000;

pub const NlMsgHdr = extern struct {
    len: u32,
    type: u16,
    flags: u16,
    seq: u32,
    pid: u32,
};

pub const IfInfoMsg = extern struct {
    family: u8,
    _pad: u8 = 0,
    type: u16,
    index: i32,
    flags: u32,
    change: u32,
};

pub const IfAddrMsg = extern struct {
    family: u8,
    prefixlen: u8,
    flags: u8,
    scope: u8,
    index: u32,
};

pub const RtAttr = extern struct {
    len: u16,
    type: u16,
};

comptime {
    std.debug.assert(@sizeOf(NlMsgHdr) == 16);
    std.debug.assert(@sizeOf(IfInfoMsg) == 16);
    std.debug.assert(@sizeOf(IfAddrMsg) == 8);
    std.debug.assert(@sizeOf(RtAttr) == 4);
}

fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

// ---- typed results ----------------------------------------------------------

/// One interface address (AF_INET: 4 significant bytes, AF_INET6: 16).
pub const Addr = struct {
    family: u8, // posix.AF.INET or posix.AF.INET6
    prefix: u8,
    bytes: [16]u8,

    pub fn slice(self: *const Addr) []const u8 {
        return self.bytes[0..if (self.family == posix.AF.INET6) @as(usize, 16) else 4];
    }

    /// Render "a.b.c.d/p" or the RFC 5952-ish hex form for v6 into `buf`.
    pub fn format(self: *const Addr, buf: []u8) ![]const u8 {
        if (self.family == posix.AF.INET) {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{
                self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3], self.prefix,
            });
        }
        var idx: usize = 0;
        var out: usize = 0;
        while (idx < 16) : (idx += 2) {
            const group = (@as(u16, self.bytes[idx]) << 8) | self.bytes[idx + 1];
            const written = if (idx == 0)
                try std.fmt.bufPrint(buf[out..], "{x}", .{group})
            else
                try std.fmt.bufPrint(buf[out..], ":{x}", .{group});
            out += written.len;
        }
        const tail = try std.fmt.bufPrint(buf[out..], "/{d}", .{self.prefix});
        return buf[0 .. out + tail.len];
    }
};

/// One observed link with its addresses (dump()) — the typed input for
/// GET /network assembly and WAN-failover decisions.
pub const Iface = struct {
    index: i32,
    name_buf: [16]u8 = @splat(0),
    name_len: u8 = 0,
    mac: [6]u8 = @splat(0),
    has_mac: bool = false,
    /// Administratively up (IFF_UP).
    up: bool = false,
    /// Physical carrier. Prefers the explicit IFLA_CARRIER attribute;
    /// falls back to IFF_LOWER_UP when the kernel omits it.
    carrier: bool = false,
    addrs: []Addr = &.{},

    pub fn name(self: *const Iface) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// (ifindex, addr) pair out of an RTM_GETADDR dump; attach() folds these
/// into the Iface list.
pub const IfAddr = struct {
    ifindex: i32,
    addr: Addr,
};

// ---- pure parsers (unit-tested against hand-built payloads) -----------------

/// Parse a buffer of RTM_NEWLINK messages (one recv worth of an
/// RTM_GETLINK dump) into `out`. Stops at NLMSG_DONE; returns true when
/// DONE was seen (the dump is complete).
pub fn parseLinkDump(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(Iface)) Error!bool {
    var off: usize = 0;
    while (off + @sizeOf(NlMsgHdr) <= bytes.len) {
        const hdr = std.mem.bytesToValue(NlMsgHdr, bytes[off..][0..@sizeOf(NlMsgHdr)]);
        if (hdr.len < @sizeOf(NlMsgHdr) or off + hdr.len > bytes.len) return error.Truncated;
        switch (hdr.type) {
            NLMSG_DONE => return true,
            NLMSG_ERROR => return error.Truncated,
            RTM_NEWLINK => {
                const iface = try parseLinkMessage(bytes[off + @sizeOf(NlMsgHdr) .. off + hdr.len]);
                out.append(gpa, iface) catch return error.OutOfMemory;
            },
            else => {}, // skip unrelated message types
        }
        off += align4(hdr.len);
    }
    return false;
}

/// One RTM_NEWLINK payload (ifinfomsg + attributes) → Iface.
pub fn parseLinkMessage(payload: []const u8) Error!Iface {
    if (payload.len < @sizeOf(IfInfoMsg)) return error.Truncated;
    const info = std.mem.bytesToValue(IfInfoMsg, payload[0..@sizeOf(IfInfoMsg)]);
    var iface: Iface = .{
        .index = info.index,
        .up = info.flags & IFF_UP != 0,
        .carrier = info.flags & IFF_LOWER_UP != 0, // fallback; IFLA_CARRIER overrides
    };

    var off: usize = @sizeOf(IfInfoMsg);
    while (off + @sizeOf(RtAttr) <= payload.len) {
        const attr = std.mem.bytesToValue(RtAttr, payload[off..][0..@sizeOf(RtAttr)]);
        if (attr.len < @sizeOf(RtAttr) or off + attr.len > payload.len) return error.Truncated;
        const data = payload[off + @sizeOf(RtAttr) .. off + attr.len];
        switch (attr.type) {
            IFLA_IFNAME => {
                // NUL-terminated string attribute.
                const n = std.mem.indexOfScalar(u8, data, 0) orelse data.len;
                iface.name_len = @intCast(@min(n, iface.name_buf.len));
                @memcpy(iface.name_buf[0..iface.name_len], data[0..iface.name_len]);
            },
            IFLA_ADDRESS => if (data.len == 6) {
                @memcpy(&iface.mac, data[0..6]);
                iface.has_mac = true;
            },
            IFLA_CARRIER => if (data.len >= 1) {
                iface.carrier = data[0] != 0;
            },
            else => {},
        }
        off += align4(attr.len);
    }
    return iface;
}

/// Parse a buffer of RTM_NEWADDR messages (RTM_GETADDR dump) into `out`.
/// Returns true when NLMSG_DONE was seen.
pub fn parseAddrDump(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(IfAddr)) Error!bool {
    var off: usize = 0;
    while (off + @sizeOf(NlMsgHdr) <= bytes.len) {
        const hdr = std.mem.bytesToValue(NlMsgHdr, bytes[off..][0..@sizeOf(NlMsgHdr)]);
        if (hdr.len < @sizeOf(NlMsgHdr) or off + hdr.len > bytes.len) return error.Truncated;
        switch (hdr.type) {
            NLMSG_DONE => return true,
            NLMSG_ERROR => return error.Truncated,
            RTM_NEWADDR => {
                if (try parseAddrMessage(bytes[off + @sizeOf(NlMsgHdr) .. off + hdr.len])) |ia| {
                    out.append(gpa, ia) catch return error.OutOfMemory;
                }
            },
            else => {},
        }
        off += align4(hdr.len);
    }
    return false;
}

/// One RTM_NEWADDR payload → (ifindex, Addr); null for families/attrs we
/// do not track. IFA_LOCAL wins over IFA_ADDRESS when both are present
/// (IFA_ADDRESS is the peer on point-to-point links).
pub fn parseAddrMessage(payload: []const u8) Error!?IfAddr {
    if (payload.len < @sizeOf(IfAddrMsg)) return error.Truncated;
    const info = std.mem.bytesToValue(IfAddrMsg, payload[0..@sizeOf(IfAddrMsg)]);
    if (info.family != posix.AF.INET and info.family != posix.AF.INET6) return null;
    const want: usize = if (info.family == posix.AF.INET6) 16 else 4;

    var addr: ?Addr = null;
    var have_local = false;
    var off: usize = @sizeOf(IfAddrMsg);
    while (off + @sizeOf(RtAttr) <= payload.len) {
        const attr = std.mem.bytesToValue(RtAttr, payload[off..][0..@sizeOf(RtAttr)]);
        if (attr.len < @sizeOf(RtAttr) or off + attr.len > payload.len) return error.Truncated;
        const data = payload[off + @sizeOf(RtAttr) .. off + attr.len];
        if ((attr.type == IFA_ADDRESS or attr.type == IFA_LOCAL) and data.len == want) {
            if (attr.type == IFA_LOCAL or !have_local) {
                var a: Addr = .{ .family = info.family, .prefix = info.prefixlen, .bytes = @splat(0) };
                @memcpy(a.bytes[0..want], data);
                addr = a;
                if (attr.type == IFA_LOCAL) have_local = true;
            }
        }
        off += align4(attr.len);
    }
    const a = addr orelse return null;
    return .{ .ifindex = @intCast(info.index), .addr = a };
}

/// Fold parsed addresses into the interface list (allocates each iface's
/// addrs slice with `gpa`; freeIfaces releases them).
pub fn attach(gpa: std.mem.Allocator, ifaces: []Iface, addrs: []const IfAddr) Error!void {
    for (ifaces) |*iface| {
        var count: usize = 0;
        for (addrs) |ia| {
            if (ia.ifindex == iface.index) count += 1;
        }
        if (count == 0) continue;
        const slice = gpa.alloc(Addr, count) catch return error.OutOfMemory;
        var idx: usize = 0;
        for (addrs) |ia| {
            if (ia.ifindex == iface.index) {
                slice[idx] = ia.addr;
                idx += 1;
            }
        }
        iface.addrs = slice;
    }
}

// ---- live dump --------------------------------------------------------------

/// sockaddr_nl, declared locally (stable kernel ABI; keeps this module
/// independent of std.os.linux coverage).
const SockaddrNl = extern struct {
    family: u16 = linux.AF.NETLINK,
    pad: u16 = 0,
    pid: u32 = 0,
    groups: u32 = 0,
};

const NETLINK_ROUTE: u32 = 0;

fn nlSocket(groups: u32) Error!posix.fd_t {
    const rc = linux.socket(linux.AF.NETLINK, posix.SOCK.RAW | posix.SOCK.CLOEXEC, NETLINK_ROUTE);
    if (linux.errno(rc) != .SUCCESS) return error.Netlink;
    const fd: posix.fd_t = @intCast(rc);
    var sa: SockaddrNl = .{ .groups = groups };
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(SockaddrNl))) != .SUCCESS) {
        _ = linux.close(fd);
        return error.Netlink;
    }
    return fd;
}

fn sendDumpRequest(fd: posix.fd_t, msg_type: u16, seq: u32) Error!void {
    const Request = extern struct {
        hdr: NlMsgHdr,
        // RTM_GETLINK wants ifinfomsg, RTM_GETADDR ifaddrmsg (8 bytes,
        // zeroed) — a zeroed 16-byte ifinfomsg-sized body satisfies both
        // dump forms (the kernel reads only the family byte for dumps).
        body: IfInfoMsg,
    };
    var req: Request = .{
        .hdr = .{
            .len = @sizeOf(Request),
            .type = msg_type,
            .flags = NLM_F_REQUEST | NLM_F_DUMP,
            .seq = seq,
            .pid = 0,
        },
        .body = .{ .family = 0, .type = 0, .index = 0, .flags = 0, .change = 0 },
    };
    const rc = linux.sendto(fd, @ptrCast(&req), @sizeOf(Request), 0, null, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Netlink;
}

fn recvDump(fd: posix.fd_t, comptime parse: anytype, gpa: std.mem.Allocator, out: anytype) Error!void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const rc = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        if (linux.errno(rc) != .SUCCESS) return error.Netlink;
        const n: usize = rc;
        if (n == 0) return error.Netlink;
        if (try parse(gpa, buf[0..n], out)) return; // NLMSG_DONE seen
    }
}

/// Snapshot every link with its v4/v6 addresses. Caller frees with
/// freeIfaces().
pub fn dump(gpa: std.mem.Allocator) Error![]Iface {
    const fd = try nlSocket(0);
    defer _ = linux.close(fd);

    var ifaces: std.ArrayList(Iface) = .empty;
    errdefer ifaces.deinit(gpa);
    try sendDumpRequest(fd, RTM_GETLINK, 1);
    try recvDump(fd, parseLinkDump, gpa, &ifaces);

    var addrs: std.ArrayList(IfAddr) = .empty;
    defer addrs.deinit(gpa);
    try sendDumpRequest(fd, RTM_GETADDR, 2);
    try recvDump(fd, parseAddrDump, gpa, &addrs);

    const slice = ifaces.toOwnedSlice(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(slice);
    try attach(gpa, slice, addrs.items);
    return slice;
}

pub fn freeIfaces(gpa: std.mem.Allocator, ifaces: []Iface) void {
    for (ifaces) |iface| {
        if (iface.addrs.len > 0) gpa.free(iface.addrs);
    }
    gpa.free(ifaces);
}

// ---- monitor ----------------------------------------------------------------

pub const EventKind = enum {
    /// RTM_NEWLINK: carrier/up/name state (publish as link.carrier when
    /// the carrier bit differs from the last observation — dedup is the
    /// subscriber's job, the monitor reports raw kernel messages).
    link_changed,
    /// RTM_DELLINK.
    link_removed,
    /// RTM_NEWADDR/RTM_DELADDR on the v4/v6 groups (re-dump to resolve).
    addr_changed,
};

pub const Event = struct {
    kind: EventKind,
    ifindex: i32,
    /// Valid for link_* events (parsed from the message); empty otherwise.
    name_buf: [16]u8 = @splat(0),
    name_len: u8 = 0,
    up: bool = false,
    carrier: bool = false,

    pub fn name(self: *const Event) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Runs on the monitor thread — must not block; publish into the events
/// ring (events.zig) and return, same discipline as bus.SignalHandler.
pub const EventHandler = *const fn (ctx: ?*anyopaque, event: Event) void;

/// Kernel-notification listener on RTMGRP_LINK + v4/v6 IFADDR. One
/// dedicated thread, poll()ing the netlink fd and a wake eventfd (the
/// bus.zig loop pattern).
pub const Monitor = struct {
    gpa: std.mem.Allocator,
    fd: posix.fd_t,
    wake_fd: posix.fd_t,
    handler: EventHandler,
    ctx: ?*anyopaque,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(gpa: std.mem.Allocator, handler: EventHandler, ctx: ?*anyopaque) Error!*Monitor {
        const fd = try nlSocket(RTMGRP_LINK | RTMGRP_IPV4_IFADDR | RTMGRP_IPV6_IFADDR);
        errdefer _ = linux.close(fd);
        const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd_rc) != .SUCCESS) return error.Netlink;
        const self = gpa.create(Monitor) catch return error.OutOfMemory;
        self.* = .{ .gpa = gpa, .fd = fd, .wake_fd = @intCast(efd_rc), .handler = handler, .ctx = ctx };
        return self;
    }

    pub fn start(self: *Monitor) !void {
        if (self.thread != null) return;
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Monitor) void {
        const t = self.thread orelse return;
        self.stop_flag.store(true, .release);
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, @ptrCast(&one), 8);
        t.join();
        self.thread = null;
    }

    pub fn deinit(self: *Monitor) void {
        self.stop();
        _ = linux.close(self.fd);
        _ = linux.close(self.wake_fd);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    fn run(self: *Monitor) void {
        var buf: [16 * 1024]u8 = undefined;
        while (!self.stop_flag.load(.acquire)) {
            var pfds = [_]posix.pollfd{
                .{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&pfds, -1) catch return;
            if (pfds[1].revents & posix.POLL.IN != 0) {
                var drain: [8]u8 = undefined;
                _ = linux.read(self.wake_fd, &drain, 8);
                continue; // re-check stop_flag
            }
            if (pfds[0].revents & posix.POLL.IN == 0) continue;
            const rc = linux.recvfrom(self.fd, &buf, buf.len, 0, null, null);
            if (linux.errno(rc) != .SUCCESS) continue;
            self.dispatch(buf[0..@as(usize, rc)]);
        }
    }

    fn dispatch(self: *Monitor, bytes: []const u8) void {
        var off: usize = 0;
        while (off + @sizeOf(NlMsgHdr) <= bytes.len) {
            const hdr = std.mem.bytesToValue(NlMsgHdr, bytes[off..][0..@sizeOf(NlMsgHdr)]);
            if (hdr.len < @sizeOf(NlMsgHdr) or off + hdr.len > bytes.len) return;
            const payload = bytes[off + @sizeOf(NlMsgHdr) .. off + hdr.len];
            switch (hdr.type) {
                RTM_NEWLINK, RTM_DELLINK => {
                    if (parseLinkMessage(payload)) |iface| {
                        self.handler(self.ctx, .{
                            .kind = if (hdr.type == RTM_DELLINK) .link_removed else .link_changed,
                            .ifindex = iface.index,
                            .up = iface.up,
                            .carrier = iface.carrier,
                            .name_buf = iface.name_buf,
                            .name_len = iface.name_len,
                        });
                    } else |_| {}
                },
                RTM_NEWADDR, RTM_DELADDR => {
                    if (parseAddrMessage(payload)) |maybe| {
                        if (maybe) |ia| {
                            self.handler(self.ctx, .{ .kind = .addr_changed, .ifindex = ia.ifindex });
                        }
                    } else |_| {}
                },
                else => {},
            }
            off += align4(hdr.len);
        }
    }
};

// ---- tests ------------------------------------------------------------------

/// Test-only netlink payload builder: messages built the way the kernel
/// lays them out (4-byte aligned headers and attributes).
const PayloadBuilder = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    msg_start: usize = 0,

    fn beginMessage(self: *PayloadBuilder, msg_type: u16, body: anytype) !void {
        self.msg_start = self.buf.items.len;
        const hdr: NlMsgHdr = .{ .len = 0, .type = msg_type, .flags = 0, .seq = 1, .pid = 0 };
        try self.buf.appendSlice(self.gpa, std.mem.asBytes(&hdr));
        try self.buf.appendSlice(self.gpa, std.mem.asBytes(&body));
    }

    fn addAttr(self: *PayloadBuilder, attr_type: u16, data: []const u8) !void {
        const attr: RtAttr = .{ .len = @intCast(@sizeOf(RtAttr) + data.len), .type = attr_type };
        try self.buf.appendSlice(self.gpa, std.mem.asBytes(&attr));
        try self.buf.appendSlice(self.gpa, data);
        while (self.buf.items.len % 4 != 0) try self.buf.append(self.gpa, 0);
    }

    fn endMessage(self: *PayloadBuilder) void {
        const len: u32 = @intCast(self.buf.items.len - self.msg_start);
        @memcpy(self.buf.items[self.msg_start..][0..4], std.mem.asBytes(&len));
    }

    fn addDone(self: *PayloadBuilder) !void {
        const hdr: NlMsgHdr = .{ .len = @sizeOf(NlMsgHdr), .type = NLMSG_DONE, .flags = 0, .seq = 1, .pid = 0 };
        try self.buf.appendSlice(self.gpa, std.mem.asBytes(&hdr));
    }

    fn deinit(self: *PayloadBuilder) void {
        self.buf.deinit(self.gpa);
    }
};

test "parseLinkDump: name, mac, flags, explicit carrier, DONE terminator" {
    const gpa = std.testing.allocator;
    var b: PayloadBuilder = .{ .gpa = gpa };
    defer b.deinit();

    // eth0: up, IFF_LOWER_UP unset but IFLA_CARRIER=1 (attr must win).
    try b.beginMessage(RTM_NEWLINK, IfInfoMsg{
        .family = 0,
        .type = 1,
        .index = 2,
        .flags = IFF_UP | IFF_RUNNING,
        .change = 0,
    });
    try b.addAttr(IFLA_IFNAME, "eth0\x00");
    try b.addAttr(IFLA_ADDRESS, &.{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 });
    try b.addAttr(IFLA_CARRIER, &.{1});
    b.endMessage();

    // wlan0: down, no carrier attr, no lower-up.
    try b.beginMessage(RTM_NEWLINK, IfInfoMsg{
        .family = 0,
        .type = 1,
        .index = 3,
        .flags = 0,
        .change = 0,
    });
    try b.addAttr(IFLA_IFNAME, "wlan0\x00");
    b.endMessage();
    try b.addDone();

    var out: std.ArrayList(Iface) = .empty;
    defer out.deinit(gpa);
    const done = try parseLinkDump(gpa, b.buf.items, &out);
    try std.testing.expect(done);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);

    const eth = out.items[0];
    try std.testing.expectEqual(@as(i32, 2), eth.index);
    try std.testing.expectEqualStrings("eth0", eth.name());
    try std.testing.expect(eth.up);
    try std.testing.expect(eth.carrier);
    try std.testing.expect(eth.has_mac);
    try std.testing.expectEqual([6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }, eth.mac);

    const wlan = out.items[1];
    try std.testing.expectEqualStrings("wlan0", wlan.name());
    try std.testing.expect(!wlan.up);
    try std.testing.expect(!wlan.carrier);
    try std.testing.expect(!wlan.has_mac);
}

test "parseLinkMessage: IFF_LOWER_UP is the carrier fallback" {
    const gpa = std.testing.allocator;
    var b: PayloadBuilder = .{ .gpa = gpa };
    defer b.deinit();
    try b.beginMessage(RTM_NEWLINK, IfInfoMsg{
        .family = 0,
        .type = 1,
        .index = 4,
        .flags = IFF_UP | IFF_LOWER_UP,
        .change = 0,
    });
    try b.addAttr(IFLA_IFNAME, "eth1\x00");
    b.endMessage();

    const iface = try parseLinkMessage(b.buf.items[@sizeOf(NlMsgHdr)..]);
    try std.testing.expect(iface.carrier);
    try std.testing.expect(iface.up);
}

test "parseAddrDump + attach: v4 IFA_LOCAL preference and v6 addresses" {
    const gpa = std.testing.allocator;
    var b: PayloadBuilder = .{ .gpa = gpa };
    defer b.deinit();

    // eth0 v4: both IFA_ADDRESS (peer) and IFA_LOCAL — LOCAL must win.
    try b.beginMessage(RTM_NEWADDR, IfAddrMsg{ .family = posix.AF.INET, .prefixlen = 24, .flags = 0, .scope = 0, .index = 2 });
    try b.addAttr(IFA_ADDRESS, &.{ 10, 0, 2, 255 });
    try b.addAttr(IFA_LOCAL, &.{ 10, 0, 2, 15 });
    b.endMessage();

    // eth0 v6.
    const v6 = [16]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try b.beginMessage(RTM_NEWADDR, IfAddrMsg{ .family = posix.AF.INET6, .prefixlen = 64, .flags = 0, .scope = 0, .index = 2 });
    try b.addAttr(IFA_ADDRESS, &v6);
    b.endMessage();

    // Unrelated family (must be ignored, not an error).
    try b.beginMessage(RTM_NEWADDR, IfAddrMsg{ .family = 17, .prefixlen = 0, .flags = 0, .scope = 0, .index = 2 });
    b.endMessage();
    try b.addDone();

    var addrs: std.ArrayList(IfAddr) = .empty;
    defer addrs.deinit(gpa);
    const done = try parseAddrDump(gpa, b.buf.items, &addrs);
    try std.testing.expect(done);
    try std.testing.expectEqual(@as(usize, 2), addrs.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 2, 15 }, addrs.items[0].addr.slice());
    try std.testing.expectEqual(@as(u8, 24), addrs.items[0].addr.prefix);
    try std.testing.expectEqualSlices(u8, &v6, addrs.items[1].addr.slice());

    var ifaces = [_]Iface{
        .{ .index = 2 },
        .{ .index = 9 },
    };
    try attach(gpa, &ifaces, addrs.items);
    defer for (&ifaces) |iface| {
        if (iface.addrs.len > 0) gpa.free(iface.addrs);
    };
    try std.testing.expectEqual(@as(usize, 2), ifaces[0].addrs.len);
    try std.testing.expectEqual(@as(usize, 0), ifaces[1].addrs.len);

    var fmt_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("10.0.2.15/24", try ifaces[0].addrs[0].format(&fmt_buf));
}

test "parsers reject truncated payloads instead of over-reading" {
    const gpa = std.testing.allocator;
    var b: PayloadBuilder = .{ .gpa = gpa };
    defer b.deinit();
    try b.beginMessage(RTM_NEWLINK, IfInfoMsg{ .family = 0, .type = 1, .index = 1, .flags = 0, .change = 0 });
    try b.addAttr(IFLA_IFNAME, "lo\x00");
    b.endMessage();

    var out: std.ArrayList(Iface) = .empty;
    defer out.deinit(gpa);
    // Cut into the attribute region: the declared nlmsg len now exceeds
    // the buffer.
    try std.testing.expectError(error.Truncated, parseLinkDump(gpa, b.buf.items[0 .. b.buf.items.len - 4], &out));
    // A dump without DONE parses fine but reports incompleteness.
    try std.testing.expectEqual(false, try parseLinkDump(gpa, b.buf.items, &out));
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}

test "live dump finds loopback (Linux always has lo)" {
    const gpa = std.testing.allocator;
    const ifaces = dump(gpa) catch |err| switch (err) {
        // Sandboxed test environments may deny AF_NETLINK sockets.
        error.Netlink => return error.SkipZigTest,
        else => return err,
    };
    defer freeIfaces(gpa, ifaces);
    try std.testing.expect(ifaces.len >= 1);
    const lo = for (ifaces) |*iface| {
        if (std.mem.eql(u8, iface.name(), "lo")) break iface;
    } else return error.NoLoopback;
    try std.testing.expect(lo.up);
}
