//! Network-config rendering: astrod's desired state (store) → daemon-native
//! files, per the docs/07 §2 rendering model as amended by the phase-3
//! decisions:
//!
//!   dhcpcd  ← /run/astro/net/dhcpcd.conf (interface allowlist, static
//!             blocks, per-interface `metric N` implementing the WAN
//!             order — dhcpcd.conf(5) `metric`; NO rtnetlink surgery).
//!             Bootstrap: tmpfiles pre-creates that path as a symlink to
//!             the baked /etc/astro/dhcpcd-fallback.conf; the first render
//!             atomically replaces the symlink with a real file (rename(2)
//!             replaces the LINK, never writes through it), then
//!             reloadDhcpcd() rebinds the running daemon. dhcpcd NEVER
//!             depends on astrod (control plane, not data plane) — it
//!             starts fine on the fallback.
//!   resolv  ← /run/astro/resolv.conf (the /etc/resolv.conf symlink target;
//!             one writer). Inputs: static DNS from the store (wins) +
//!             DHCP-learned DNS from the lease files the dhcpcd hook
//!             writes, WAN-preferred interface first.
//!   leases  ← /run/astro/net/leases/<iface>.json, written BY ROOT (the
//!             dhcpcd hook, usr/lib/astro/dhcpcd-hook.sh in the common
//!             overlay); astrod inotify-watches the directory and
//!             re-renders resolv.conf + publishes observed-state events.
//!
//! RELOAD MECHANISM (verified in dhcpcd-10.3.2 source; the manpage's
//! `dhcpcd -n` is a control-socket command, not a signal, whenever the
//! socket exists — src/dhcpcd.c:2425..2460):
//!   - wire format: NUL-separated argv written in one shot to the
//!     PRIVILEGED control socket @RUNDIR@/sock = /run/dhcpcd/sock
//!     (src/control.c control_send:557, make_path:381 with the template's
//!     --rundir=/run/dhcpcd); we send "dhcpcd\0-n\0".
//!   - server side: dhcpcd_handleargs (src/dhcpcd.c:1611) getopt-parses
//!     the argv, 'n' → reload_config() + reconf_reboot(reboot=true) —
//!     i.e. re-read -f config and rebind, exactly what we need after a
//!     re-render. (SIGHUP does the same, src/dhcpcd.c:1550, but the
//!     daemon's pid is not ours to discover race-free; the socket is the
//!     supported client channel.)
//!   - access: the priv socket is 0660 root:<controlgroup>
//!     (src/control.c:400,419 chown to ctx->control_group), so BOTH the
//!     rendered config and the baked fallback say `controlgroup astrod` —
//!     uid-300 astrod may connect without owning any part of dhcpcd.
//!   - fallback: if the socket cannot be reached the daemon is not
//!     running; asking dinit to start the service (existing dinit.zig
//!     client — a mechanism start, not a shell-out) makes it read the
//!     freshly rendered config. Both failing is ReloadFailed.
//!
//! HTTP handlers for the network group live here too (update.zig
//! discipline: pub handlers + a module-global Manager set by main.zig;
//! the route-table entries in router.zig are the shared-file followup).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const fsutil = @import("fsutil.zig");
const store_mod = @import("store.zig");
const sync = @import("sync.zig");
const events_mod = @import("events.zig");
const link = @import("link.zig");
const wifi_mod = @import("wifi.zig");
const dinit = @import("dinit.zig");
const router = @import("router.zig");

/// Rendered-config paths (tmpfiles-owned parents; see the overlay's
/// usr/lib/tmpfiles.d/astrod.conf for the ownership map).
pub const dhcpcd_conf_path = "/run/astro/net/dhcpcd.conf";
pub const dhcpcd_fallback_path = "/etc/astro/dhcpcd-fallback.conf";
pub const resolv_conf_path = "/run/astro/resolv.conf";
pub const lease_dir = "/run/astro/net/leases";

/// dhcpcd's privileged control socket: RUNDIR "/sock" with the port's
/// --rundir=/run/dhcpcd (dhcpcd-10.3.2 src/defs.h CONTROLSOCKET,
/// src/control.c make_path with a null ifname — manager mode).
pub const dhcpcd_control_socket = "/run/dhcpcd/sock";
pub const dhcpcd_service = "dhcpcd";

/// Event type for lease/observed-state changes (docs/06 §4 dotted form).
pub const event_ethernet_state = events_mod.types.network_ethernet_state;

/// libc resolver limit (resolv.h MAXNS): only the first 3 nameserver
/// lines count, so the renderer stops there deterministically.
pub const max_nameservers = 3;

pub const Error = error{
    /// Retained spine member (nothing returns it since the fill).
    NotImplemented,
    OutOfMemory,
    /// Filesystem failure writing a rendered artifact.
    RenderFailed,
    /// dhcpcd could not be poked (socket down AND dinit start failed).
    ReloadFailed,
    /// inotify setup failed (missing lease dir or fd exhaustion).
    WatchFailed,
    /// Lease JSON was malformed or missed required fields.
    InvalidLease,
};

/// One parsed lease file (leases/<iface>.json, written by the root hook).
/// Field set mirrors the hook's output document; unknown fields are
/// tolerated (a newer hook may add facts before astrod learns them).
pub const Lease = struct {
    iface: []const u8 = "",
    /// DHCP/RA-learned resolvers, in hook order.
    dns: []const []const u8 = &.{},
    domain: ?[]const u8 = null,
    address: ?[]const u8 = null,
    prefix: ?u8 = null,
    gateway: ?[]const u8 = null,
    /// Unix seconds at export time (hook `date +%s`).
    ts: ?i64 = null,
};

// ---- classification helpers -------------------------------------------------

/// WAN-order class of an interface name ("ethernet"/"wifi") — the same
/// naming the store's network.wan.order uses. Kernel names on Astro
/// boards: eth*/en* wired, wlan* wireless.
pub fn classOfInterface(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "wlan")) return "wifi";
    if (std.mem.startsWith(u8, name, "eth") or std.mem.startsWith(u8, name, "en")) return "ethernet";
    if (std.mem.eql(u8, name, "lo")) return "loopback";
    return "other";
}

/// fnmatch pattern covering a WAN class in dhcpcd.conf `interface` blocks.
fn classGlob(class: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, class, "ethernet")) return "eth*";
    if (std.mem.eql(u8, class, "wifi")) return "wlan*";
    return null; // future classes (cellular) render nothing yet
}

/// Position of `class` in the WAN order; null when unranked.
fn classRank(order: []const []const u8, class: []const u8) ?usize {
    for (order, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry, class)) return idx;
    }
    return null;
}

/// Route metric for a WAN-order position: lowest wins (dhcpcd.conf(5)),
/// rank 0 → 100, rank 1 → 200, … Unranked classes sit at 1000 — above
/// every ranked class yet below dhcpcd's own 1000+ifindex defaults only
/// by accident, so we always render explicitly.
fn metricForRank(rank: ?usize) u32 {
    const r = rank orelse return 1000;
    return @intCast(100 * (r + 1));
}

fn metricForName(order: []const []const u8, name: []const u8) u32 {
    return metricForRank(classRank(order, classOfInterface(name)));
}

/// Kernel interface-name shape: 1..15 chars, no '/', no leading '-',
/// nothing that could break out of a rendered line or a file name.
pub fn validIfaceName(name: []const u8) bool {
    if (name.len == 0 or name.len > 15) return false;
    if (name[0] == '-' or name[0] == '.') return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return false,
        }
    }
    return true;
}

/// Strict dotted-quad IPv4 (no leading '+', each octet 0..255).
pub fn parseIpv4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var idx: usize = 0;
    while (it.next()) |part| {
        if (idx == 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        var val: u32 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return null;
            val = val * 10 + (c - '0');
        }
        if (val > 255) return null;
        out[idx] = @intCast(val);
        idx += 1;
    }
    return if (idx == 4) out else null;
}

/// Loose IP-literal check for DNS entries: strict v4, or a v6-shaped
/// hex-and-colon string (the resolver, not astrod, is the final judge).
fn isIpLiteral(s: []const u8) bool {
    if (parseIpv4(s) != null) return true;
    if (std.mem.indexOfScalar(u8, s, ':') == null) return false;
    if (s.len < 2 or s.len > 45) return false;
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F', ':', '.' => {},
            else => return false,
        }
    }
    return true;
}

fn appendFmt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Error!void {
    const s = std.fmt.allocPrint(gpa, fmt, args) catch return error.OutOfMemory;
    defer gpa.free(s);
    out.appendSlice(gpa, s) catch return error.OutOfMemory;
}

// ---- renderers --------------------------------------------------------------

/// Render the dhcpcd.conf document from the store: header, global options
/// (`nohook resolv.conf`, `controlgroup astrod`, allowlist), WAN-order
/// class blocks carrying `metric`, then one block per configured
/// interface (static ip_address/routers for mode=static). Pure — caller
/// writes it via writeRendered.
pub fn renderDhcpcdConf(allocator: std.mem.Allocator, st: *store_mod.Store) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    st.mu.lockShared();
    defer st.mu.unlockShared();
    const net = &st.config.network;

    out.appendSlice(allocator,
        \\# dhcpcd.conf — RENDERED BY ASTROD, DO NOT EDIT (docs/07 §2).
        \\# Desired state lives in /data/config/astro.json (network.*); this
        \\# file is regenerated on astrod startup and on every config change.
        \\# One resolv.conf writer: astrod renders /run/astro/resolv.conf from
        \\# store DNS + the lease exports (hook 60-astro-lease), so dhcpcd's
        \\# own resolv.conf hook stays off in BOTH this and the fallback conf.
        \\nohook resolv.conf
        \\# Send the system hostname to the DHCP server (dhcpcd.conf(5): an
        \\# empty name means the current kernel hostname).
        \\hostname
        \\# chown /run/dhcpcd/sock root:astrod so unprivileged astrod can send
        \\# the rebind command after re-rendering (dhcpcd-10.3.2 control.c).
        \\controlgroup astrod
        \\# AD-015: dhcpcd owns addressing on wired AND wifi — iwd only
        \\# associates (EnableNetworkConfiguration=false).
        \\allowinterfaces eth* wlan*
    ) catch return error.OutOfMemory;
    // Interfaces configured under names our globs miss are allowed
    // explicitly (allowinterfaces is additive within one line list).
    {
        var it = net.ethernet.map.iterator();
        var extras = false;
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (std.mem.startsWith(u8, name, "eth") or std.mem.startsWith(u8, name, "wlan")) continue;
            if (!extras) {
                out.appendSlice(allocator, "\nallowinterfaces") catch return error.OutOfMemory;
                extras = true;
            }
            try appendFmt(allocator, &out, " {s}", .{name});
        }
    }
    out.appendSlice(allocator,
        \\
        \\
        \\# WAN policy (network.wan.order): route preference via metrics,
        \\# lowest wins — never rtnetlink surgery from astrod.
        \\
    ) catch return error.OutOfMemory;
    for (net.wan.order, 0..) |class, idx| {
        const glob = classGlob(class) orelse continue;
        try appendFmt(allocator, &out, "interface {s}\nmetric {d}\n", .{ glob, metricForRank(idx) });
    }

    var it = net.ethernet.map.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const eth = entry.value_ptr.*;
        try appendFmt(allocator, &out, "\n# network.ethernet.{s}\ninterface {s}\nmetric {d}\n", .{
            name, name, metricForName(net.wan.order, name),
        });
        const is_static = std.mem.eql(u8, eth.ipv4.mode, "static");
        if (is_static and eth.ipv4.address != null and eth.ipv4.prefix != null) {
            try appendFmt(allocator, &out, "static ip_address={s}/{d}\n", .{ eth.ipv4.address.?, eth.ipv4.prefix.? });
            if (eth.ipv4.gateway) |gw| {
                try appendFmt(allocator, &out, "static routers={s}\n", .{gw});
            }
        } else if (is_static) {
            // Defensive: a hand-edited document may say static without an
            // address; DHCP is the safe degradation (PUT/PATCH validate).
            out.appendSlice(allocator, "# static requested but address/prefix missing; leaving DHCP\n") catch return error.OutOfMemory;
        }
    }

    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Render resolv.conf from static DNS in the store (wins per interface)
/// plus the DHCP-learned servers in `leases`, deduplicated, capped at
/// max_nameservers, interfaces visited in WAN-order preference. The
/// search domain is the preferred interface's DHCP domain (static config
/// carries no domain in schema 1).
pub fn renderResolvConf(allocator: std.mem.Allocator, leases: []const Lease, st: *store_mod.Store) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    out.appendSlice(allocator,
        \\# resolv.conf — rendered by astrod, DO NOT EDIT (docs/07 §2: one
        \\# writer). Inputs: static DNS from /data/config/astro.json (wins
        \\# per interface) + DHCP-learned servers exported by the dhcpcd
        \\# lease hook, WAN-preferred interface first.
        \\
    ) catch return error.OutOfMemory;

    const Candidate = struct { name: []const u8, rank: usize };
    var cands: std.ArrayList(Candidate) = .empty;
    defer cands.deinit(allocator);

    const order = st.getWanOrder();
    {
        st.mu.lockShared();
        defer st.mu.unlockShared();
        var it = st.config.network.ethernet.map.iterator();
        while (it.next()) |entry| {
            const rank = classRank(order, classOfInterface(entry.key_ptr.*)) orelse order.len;
            cands.append(allocator, .{ .name = entry.key_ptr.*, .rank = rank }) catch return error.OutOfMemory;
        }
    }
    outer: for (leases) |lease| {
        for (cands.items) |c| {
            if (std.mem.eql(u8, c.name, lease.iface)) continue :outer;
        }
        const rank = classRank(order, classOfInterface(lease.iface)) orelse order.len;
        cands.append(allocator, .{ .name = lease.iface, .rank = rank }) catch return error.OutOfMemory;
    }
    std.mem.sort(Candidate, cands.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var servers: std.ArrayList([]const u8) = .empty;
    defer servers.deinit(allocator);
    var domain: ?[]const u8 = null;
    for (cands.items) |c| {
        const lease: ?*const Lease = for (leases) |*l| {
            if (std.mem.eql(u8, l.iface, c.name)) break l;
        } else null;
        if (domain == null) {
            if (lease) |l| {
                if (l.domain) |d| {
                    if (d.len > 0) domain = d;
                }
            }
        }
        const static_dns: []const []const u8 = if (st.getEthernet(c.name)) |eth| eth.dns else &.{};
        const dns = if (static_dns.len > 0) static_dns else if (lease) |l| l.dns else continue;
        for (dns) |ns| {
            if (servers.items.len >= max_nameservers) break;
            const dup = for (servers.items) |seen| {
                if (std.mem.eql(u8, seen, ns)) break true;
            } else false;
            if (!dup) servers.append(allocator, ns) catch return error.OutOfMemory;
        }
    }

    if (domain) |d| try appendFmt(allocator, &out, "search {s}\n", .{d});
    for (servers.items) |ns| try appendFmt(allocator, &out, "nameserver {s}\n", .{ns});
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

// ---- leases -----------------------------------------------------------------

/// Parse one lease file's JSON into a Lease (arena-allocated by caller).
/// Unknown fields tolerated (forward compat with a newer hook).
pub fn parseLease(allocator: std.mem.Allocator, json_bytes: []const u8) Error!Lease {
    const lease = std.json.parseFromSliceLeaky(Lease, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidLease,
    };
    if (!validIfaceName(lease.iface)) return error.InvalidLease;
    return lease;
}

/// Read every <iface>.json in `dir` (raw getdents64 — the std.fs dir
/// walker sits behind std.Io, which daemon code avoids; see fsutil.zig).
/// A missing directory or an unparseable file yields no entry rather than
/// an error: the watcher may race the hook's tmp+rename, and a torn read
/// must never take resolv rendering down. Caller frees via arena.
pub fn readLeases(allocator: std.mem.Allocator, dir: []const u8) error{OutOfMemory}![]Lease {
    var list: std.ArrayList(Lease) = .empty;
    errdefer list.deinit(allocator);

    const dir_z = posix.toPosixPath(dir) catch return list.toOwnedSlice(allocator);
    const rc = linux.openat(linux.AT.FDCWD, &dir_z, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(rc) != .SUCCESS) return list.toOwnedSlice(allocator);
    const fd: posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n_rc = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n_rc) != .SUCCESS) break;
        const n: usize = n_rc;
        if (n == 0) break;
        var off: usize = 0;
        while (off + 19 <= n) {
            // struct linux_dirent64: u64 ino, i64 off, u16 reclen, u8 type,
            // char name[] (NUL-terminated) — stable kernel ABI.
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            if (reclen < 19 or off + reclen > n) break;
            const name_bytes = buf[off + 19 .. off + reclen];
            const name_len = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
            const name = name_bytes[0..name_len];
            off += reclen;
            if (name.len == 0 or name[0] == '.') continue;
            if (!std.mem.endsWith(u8, name, ".json")) continue;

            const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }) catch return error.OutOfMemory;
            defer allocator.free(path);
            const bytes = fsutil.readFileAlloc(allocator, path, 64 * 1024) catch continue;
            defer allocator.free(bytes);
            const lease = parseLease(allocator, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue, // torn/hostile file: skip, never fail the render
            };
            list.append(allocator, lease) catch return error.OutOfMemory;
        }
    }
    return list.toOwnedSlice(allocator);
}

// ---- rendered-file install + reload -----------------------------------------

/// Atomically install rendered `content` at `path` (tmp + rename in the
/// same directory). rename(2) replaces the destination NAME, so the
/// tmpfiles bootstrap symlink at dhcpcd_conf_path becomes a regular file
/// on the first render instead of writing through to /etc.
pub fn writeRendered(path: []const u8, content: []const u8) Error!void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.RenderFailed;
    fsutil.writeFileSync(tmp, content) catch return error.RenderFailed;
    fsutil.rename(tmp, path) catch return error.RenderFailed;
}

/// `dhcpcd -n` without the fork: write the NUL-separated argv
/// ("dhcpcd\0-n\0") to the privileged control socket — the daemon
/// re-reads its -f config and rebinds (see the module header for the
/// verified source trail). Returns false when the socket is unreachable.
fn controlSocketRebind() bool {
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = @splat(0) };
    const path = dhcpcd_control_socket;
    @memcpy(addr.path[0..path.len], path);

    const rc = linux.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) != .SUCCESS)
        return false;

    const cmd = "dhcpcd\x00-n\x00";
    const wrc = linux.write(fd, cmd.ptr, cmd.len);
    if (linux.errno(wrc) != .SUCCESS) return false;
    return wrc == cmd.len;
}

/// Poke the running dhcpcd to re-read its config and rebind. Primary:
/// the control-socket command (above). Fallback: the socket being gone
/// means dhcpcd is down — ask dinit to start the service (it reads the
/// rendered config on start); dhcpcd never depends on astrod, but astrod
/// may legitimately revive it after a crash-loop.
pub fn reloadDhcpcd() Error!void {
    if (controlSocketRebind()) return;
    dinit.startServiceByName(dinit.default_socket_path, dhcpcd_service) catch return error.ReloadFailed;
}

// ---- lease watcher ----------------------------------------------------------

// inotify ABI constants (linux/inotify.h — declared locally, link.zig
// convention: stable kernel ABI over chasing std coverage).
const IN_CLOSE_WRITE: u32 = 0x8;
const IN_MOVED_TO: u32 = 0x80;
const IN_DELETE: u32 = 0x200;

/// Runs on the watcher thread — publish into the events ring and return
/// (same discipline as bus.SignalHandler / link.EventHandler).
pub const LeaseEvent = struct {
    /// Interface whose lease file changed (parsed from the file name).
    iface_buf: [16]u8 = @splat(0),
    iface_len: u8 = 0,
    /// True when the lease file was deleted (lease lost / carrier gone).
    removed: bool = false,

    pub fn iface(self: *const LeaseEvent) []const u8 {
        return self.iface_buf[0..self.iface_len];
    }
};

pub const LeaseHandler = *const fn (ctx: ?*anyopaque, event: LeaseEvent) void;

/// inotify (raw syscalls: inotify_init1/inotify_add_watch) watcher on
/// lease_dir for IN_CLOSE_WRITE|IN_MOVED_TO|IN_DELETE, one thread, the
/// poll-plus-wake-eventfd loop pattern shared with link.Monitor.
pub const LeaseWatcher = struct {
    gpa: std.mem.Allocator,
    fd: posix.fd_t,
    wake_fd: posix.fd_t,
    handler: LeaseHandler,
    ctx: ?*anyopaque,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(gpa: std.mem.Allocator, dir: []const u8, handler: LeaseHandler, ctx: ?*anyopaque) Error!*LeaseWatcher {
        const dir_z = posix.toPosixPath(dir) catch return error.WatchFailed;
        const irc = linux.inotify_init1(linux.IN.CLOEXEC);
        if (linux.errno(irc) != .SUCCESS) return error.WatchFailed;
        const fd: posix.fd_t = @intCast(irc);
        errdefer _ = linux.close(fd);
        const wrc = linux.inotify_add_watch(fd, &dir_z, IN_CLOSE_WRITE | IN_MOVED_TO | IN_DELETE);
        if (linux.errno(wrc) != .SUCCESS) return error.WatchFailed;
        const erc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(erc) != .SUCCESS) return error.WatchFailed;
        errdefer _ = linux.close(@as(posix.fd_t, @intCast(erc)));

        const self = gpa.create(LeaseWatcher) catch return error.OutOfMemory;
        self.* = .{ .gpa = gpa, .fd = fd, .wake_fd = @intCast(erc), .handler = handler, .ctx = ctx };
        return self;
    }

    pub fn start(self: *LeaseWatcher) Error!void {
        if (self.thread != null) return;
        self.stop_flag.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return error.WatchFailed;
    }

    pub fn stop(self: *LeaseWatcher) void {
        const t = self.thread orelse return;
        self.stop_flag.store(true, .release);
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, @ptrCast(&one), 8);
        t.join();
        self.thread = null;
    }

    pub fn deinit(self: *LeaseWatcher) void {
        self.stop();
        _ = linux.close(self.fd);
        _ = linux.close(self.wake_fd);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    fn run(self: *LeaseWatcher) void {
        var buf: [4096]u8 align(8) = undefined;
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
            const rc = linux.read(self.fd, &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS) continue;
            self.dispatch(buf[0..@as(usize, rc)]);
        }
    }

    fn dispatch(self: *LeaseWatcher, bytes: []const u8) void {
        // struct inotify_event: i32 wd, u32 mask, u32 cookie, u32 len,
        // char name[len] (NUL-padded) — stable kernel ABI.
        var off: usize = 0;
        while (off + 16 <= bytes.len) {
            const mask = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
            const name_area_len = std.mem.readInt(u32, bytes[off + 12 ..][0..4], .little);
            if (off + 16 + name_area_len > bytes.len) return;
            const name_bytes = bytes[off + 16 .. off + 16 + name_area_len];
            off += 16 + name_area_len;

            const name_len = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
            const name = name_bytes[0..name_len];
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            const iface_name = name[0 .. name.len - ".json".len];
            if (!validIfaceName(iface_name)) continue;

            var event: LeaseEvent = .{ .removed = mask & IN_DELETE != 0 };
            event.iface_len = @intCast(@min(iface_name.len, event.iface_buf.len));
            @memcpy(event.iface_buf[0..event.iface_len], iface_name[0..event.iface_len]);
            self.handler(self.ctx, event);
        }
    }
};

// ---- manager ----------------------------------------------------------------

/// The netconf reconciler: owns render → install → reload, the lease
/// watcher, and the docs/06 §4 generation counters (generation bumps on
/// every persisted desired-state change; observedGeneration reaches it
/// once dhcpcd is running the rendered result — clients await
/// convergence). One instance, constructed by main.zig (followup),
/// handlers reach it via `global` (update.zig discipline).
pub const Manager = struct {
    gpa: std.mem.Allocator,
    st: *store_mod.Store,
    event_bus: ?*events_mod.EventBus,
    /// Long-lived copies of config strings written at runtime (PUT/PATCH
    /// intern their inputs here — the store's own backing memory is the
    /// load-time parse arena, which mutation must never point into a
    /// request arena). Never freed before deinit; config writes are rare
    /// and small by design.
    arena_state: std.heap.ArenaAllocator,
    arena_mu: sync.Mutex = .{},
    /// Serializes render+install+reload sequences across handler threads
    /// and the watcher thread (shared .tmp path).
    apply_mu: sync.Mutex = .{},
    /// Paths + reload hook are per-instance so tests can point them at a
    /// scratch directory and stub the daemon poke; production uses the
    /// defaults.
    conf_path: []const u8 = dhcpcd_conf_path,
    resolv_path: []const u8 = resolv_conf_path,
    leases_path: []const u8 = lease_dir,
    reload_fn: *const fn () Error!void = reloadDhcpcd,
    watcher: ?*LeaseWatcher = null,
    // usize, not u64: arm32 has no native 64-bit atomics (zig's
    // std.atomic.Value rejects >word-size types for the target) and the
    // counter only needs monotonicity for convergence comparison; JSON
    // marshaling widens to u64.
    gen: std.atomic.Value(usize) = .init(1),
    observed_gen: std.atomic.Value(usize) = .init(0),

    pub fn init(gpa: std.mem.Allocator, st: *store_mod.Store, event_bus: ?*events_mod.EventBus) error{OutOfMemory}!*Manager {
        const self = try gpa.create(Manager);
        self.* = .{
            .gpa = gpa,
            .st = st,
            .event_bus = event_bus,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
        };
        return self;
    }

    pub fn deinit(self: *Manager) void {
        if (self.watcher) |w| w.deinit();
        self.arena_state.deinit();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Startup sequence (main.zig calls this once, after the listeners
    /// exist is fine — dhcpcd does not wait for us): render everything
    /// from the store, poke dhcpcd, start watching lease exports.
    /// Failures degrade (fallback conf keeps DHCP alive) and are logged,
    /// never fatal — control plane must not take the data plane down.
    pub fn start(self: *Manager) void {
        self.applyDhcpcd();
        self.applyResolv();
        const w = LeaseWatcher.init(self.gpa, self.leases_path, onLeaseEvent, self) catch |err| {
            std.log.warn("netconf: lease watcher unavailable ({t}); DHCP DNS updates degrade to restart-time", .{err});
            return;
        };
        w.start() catch |err| {
            std.log.warn("netconf: lease watcher thread failed ({t})", .{err});
            w.deinit();
            return;
        };
        self.watcher = w;
    }

    /// Render dhcpcd.conf → atomic install → rebind. observedGeneration
    /// advances only when the whole chain succeeded.
    pub fn applyDhcpcd(self: *Manager) void {
        self.apply_mu.lock();
        defer self.apply_mu.unlock();
        const target_gen = self.gen.load(.acquire);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const conf = renderDhcpcdConf(arena.allocator(), self.st) catch |err| {
            std.log.warn("netconf: dhcpcd.conf render failed ({t})", .{err});
            return;
        };
        writeRendered(self.conf_path, conf) catch |err| {
            std.log.warn("netconf: dhcpcd.conf install failed ({t})", .{err});
            return;
        };
        self.reload_fn() catch |err| {
            std.log.warn("netconf: dhcpcd reload failed ({t}); config installed, rebind pending", .{err});
            return;
        };
        self.observed_gen.store(target_gen, .release);
    }

    /// Render resolv.conf from the store + current lease exports.
    pub fn applyResolv(self: *Manager) void {
        self.apply_mu.lock();
        defer self.apply_mu.unlock();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const leases = readLeases(arena.allocator(), self.leases_path) catch return;
        const content = renderResolvConf(arena.allocator(), leases, self.st) catch |err| {
            std.log.warn("netconf: resolv.conf render failed ({t})", .{err});
            return;
        };
        writeRendered(self.resolv_path, content) catch |err| {
            std.log.warn("netconf: resolv.conf install failed ({t})", .{err});
        };
    }

    fn bumpGeneration(self: *Manager) void {
        _ = self.gen.fetchAdd(1, .acq_rel);
    }

    pub const MutateError = error{ OutOfMemory, PersistFailed };

    /// Persist a full ethernet object for `iface` (PUT/PATCH backend):
    /// intern strings into the manager arena, swap the map entry under
    /// the store's exclusive lock, persist atomically, bump generation.
    pub fn setEthernet(self: *Manager, iface: []const u8, eth: store_mod.Config.Ethernet) MutateError!void {
        self.arena_mu.lock();
        defer self.arena_mu.unlock();
        const a = self.arena_state.allocator();
        const key = try a.dupe(u8, iface);
        const owned = try internEthernet(a, eth);

        self.st.beginMutate();
        defer self.st.endMutate();
        // Growing the map with our arena migrates its index storage away
        // from the load-time parse arena; ArenaAllocator.free on foreign
        // memory is a no-op, so the mix is safe (and never freed early).
        try self.st.config.network.ethernet.map.put(a, key, owned);
        self.st.persistLocked() catch return error.PersistFailed;
        self.bumpGeneration();
    }

    /// Persist a new WAN order (PUT /network/wan backend).
    pub fn setWanOrder(self: *Manager, order: []const []const u8) MutateError!void {
        self.arena_mu.lock();
        defer self.arena_mu.unlock();
        const a = self.arena_state.allocator();
        const owned = try a.alloc([]const u8, order.len);
        for (order, 0..) |entry, i| owned[i] = try a.dupe(u8, entry);

        self.st.beginMutate();
        defer self.st.endMutate();
        self.st.config.network.wan.order = owned;
        self.st.persistLocked() catch return error.PersistFailed;
        self.bumpGeneration();
    }

    fn internEthernet(a: std.mem.Allocator, eth: store_mod.Config.Ethernet) error{OutOfMemory}!store_mod.Config.Ethernet {
        var out: store_mod.Config.Ethernet = .{ .ipv4 = .{
            .mode = try a.dupe(u8, eth.ipv4.mode),
            .address = if (eth.ipv4.address) |s| try a.dupe(u8, s) else null,
            .prefix = eth.ipv4.prefix,
            .gateway = if (eth.ipv4.gateway) |s| try a.dupe(u8, s) else null,
        } };
        const dns = try a.alloc([]const u8, eth.dns.len);
        for (eth.dns, 0..) |s, i| dns[i] = try a.dupe(u8, s);
        out.dns = dns;
        return out;
    }

    fn publishLeaseEvent(self: *Manager, event: LeaseEvent) void {
        const bus = self.event_bus orelse return;
        var buf: [96]u8 = undefined;
        const data = std.fmt.bufPrint(&buf, "{{\"iface\":\"{s}\",\"bound\":{}}}", .{
            event.iface(), !event.removed,
        }) catch return;
        _ = bus.publishEnvelope(event_ethernet_state, null, data) catch {};
    }
};

/// Watcher-thread callback: DHCP facts changed → re-render resolv.conf
/// and surface the observed-state change on the SSE stream. Never blocks
/// on the store's exclusive lock holders beyond render time.
fn onLeaseEvent(ctx: ?*anyopaque, event: LeaseEvent) void {
    const self: *Manager = @ptrCast(@alignCast(ctx.?));
    self.applyResolv();
    self.publishLeaseEvent(event);
}

/// Module global set by main once the backend is constructed (update.zig
/// discipline); handlers answer 501 while null (unit-test builds).
pub var global: ?*Manager = null;

// ---- GET /network assembly --------------------------------------------------

const LeaseView = struct {
    address: ?[]const u8,
    prefix: ?u8,
    gateway: ?[]const u8,
    dns: []const []const u8,
    domain: ?[]const u8,
};

const IfaceView = struct {
    name: []const u8,
    type: []const u8,
    mac: ?[]const u8,
    up: bool,
    carrier: bool,
    addresses: []const []const u8,
    /// "primary" (first WAN class), "secondary" (ranked lower), "none".
    wan_role: []const u8,
    rssi_dbm: ?i16 = null,
    /// Desired state from the store (null = implicit DHCP defaults).
    config: ?store_mod.Config.Ethernet = null,
    /// DHCP-observed facts from the lease export (null = no lease).
    lease: ?LeaseView = null,
};

const NetworkView = struct {
    generation: u64,
    observedGeneration: u64,
    wan: struct { order: []const []const u8 },
    interfaces: []const IfaceView,
    wifi: ?wifi_mod.State,
};

/// Merge observed links + lease exports + desired state + wifi state into
/// the docs/06 §5.2 GET /network document. Pure and allocation-transparent
/// (caller passes a per-request arena; views alias the inputs).
pub fn assembleNetworkJson(
    allocator: std.mem.Allocator,
    ifaces: []const link.Iface,
    leases: []const Lease,
    st: *store_mod.Store,
    wifi_state: ?wifi_mod.State,
    generation: u64,
    observed_generation: u64,
) error{OutOfMemory}![]u8 {
    const order = st.getWanOrder();
    var views: std.ArrayList(IfaceView) = .empty;
    defer views.deinit(allocator);

    for (ifaces) |*iface| {
        const name = iface.name();
        const class = classOfInterface(name);
        if (std.mem.eql(u8, class, "loopback")) continue;

        var addrs: std.ArrayList([]const u8) = .empty;
        defer addrs.deinit(allocator);
        for (iface.addrs) |*addr| {
            var abuf: [64]u8 = undefined;
            const s = addr.format(&abuf) catch continue;
            try addrs.append(allocator, try allocator.dupe(u8, s));
        }

        const lease: ?LeaseView = for (leases) |*l| {
            if (std.mem.eql(u8, l.iface, name)) break .{
                .address = l.address,
                .prefix = l.prefix,
                .gateway = l.gateway,
                .dns = l.dns,
                .domain = l.domain,
            };
        } else null;

        const rank = classRank(order, class);
        try views.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .type = class,
            .mac = if (iface.has_mac) try std.fmt.allocPrint(
                allocator,
                "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}",
                .{ iface.mac[0], iface.mac[1], iface.mac[2], iface.mac[3], iface.mac[4], iface.mac[5] },
            ) else null,
            .up = iface.up,
            .carrier = iface.carrier,
            .addresses = try addrs.toOwnedSlice(allocator),
            .wan_role = if (rank) |r| (if (r == 0) "primary" else "secondary") else "none",
            .rssi_dbm = if (std.mem.eql(u8, class, "wifi"))
                (if (wifi_state) |w| w.rssi_dbm else null)
            else
                null,
            .config = st.getEthernet(name),
            .lease = lease,
        });
    }

    const doc: NetworkView = .{
        .generation = generation,
        .observedGeneration = observed_generation,
        .wan = .{ .order = order },
        .interfaces = views.items,
        .wifi = wifi_state,
    };
    return std.json.Stringify.valueAlloc(allocator, doc, .{});
}

// ---- HTTP handlers (wired into router.zig by the shared-file followup) ------

fn notWired(ctx: *router.Context) router.Response {
    const detail = std.fmt.allocPrint(
        ctx.allocator,
        "{t} {s}: the network subsystem is not wired in this build",
        .{ ctx.request.method, ctx.request.path },
    ) catch null;
    return router.problemResponse(ctx, .{
        .type = "urn:astro:problem:not-implemented",
        .title = "Not Implemented",
        .status = 501,
        .detail = detail,
    });
}

fn badRequest(ctx: *router.Context, detail: []const u8) router.Response {
    return router.problemResponse(ctx, .{
        .type = "urn:astro:problem:bad-request",
        .title = "Bad Request",
        .status = 400,
        .detail = detail,
    });
}

fn persistFailure(ctx: *router.Context) router.Response {
    return router.problemResponse(ctx, .{
        .type = "urn:astro:problem:store-persist",
        .title = "Internal Server Error",
        .status = 500,
        .detail = "the config store could not be persisted to /data",
    });
}

/// Reject anything that does not look like a kernel interface name before
/// it reaches a rendered file or a path.
fn checkIfaceParam(ctx: *router.Context) ?[]const u8 {
    const iface = ctx.param.?;
    return if (validIfaceName(iface)) iface else null;
}

/// Semantic validation for an ethernet config object (docs/06 §5.2 wire
/// shape). Returns a problem detail, or null when valid.
pub fn validateEthernet(eth: store_mod.Config.Ethernet) ?[]const u8 {
    const v4 = eth.ipv4;
    if (std.mem.eql(u8, v4.mode, "dhcp")) {
        if (v4.address != null or v4.prefix != null or v4.gateway != null)
            return "ipv4.address/prefix/gateway are only valid with ipv4.mode=\"static\"";
    } else if (std.mem.eql(u8, v4.mode, "static")) {
        const addr = v4.address orelse return "ipv4.mode=\"static\" requires ipv4.address";
        if (parseIpv4(addr) == null) return "ipv4.address must be an IPv4 dotted quad";
        const prefix = v4.prefix orelse return "ipv4.mode=\"static\" requires ipv4.prefix";
        if (prefix < 1 or prefix > 32) return "ipv4.prefix must be 1..32";
        if (v4.gateway) |gw| {
            if (parseIpv4(gw) == null) return "ipv4.gateway must be an IPv4 dotted quad";
        }
    } else {
        return "ipv4.mode must be \"dhcp\" or \"static\"";
    }
    for (eth.dns) |ns| {
        if (!isIpLiteral(ns)) return "dns entries must be IP address literals";
    }
    return null;
}

/// Validate a WAN order: known classes only, no duplicates, non-empty.
pub fn validateWanOrder(order: []const []const u8) ?[]const u8 {
    if (order.len == 0) return "order must name at least one interface class";
    for (order, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry, "ethernet") and !std.mem.eql(u8, entry, "wifi"))
            return "order entries must be \"ethernet\" or \"wifi\" (cellular is reserved)";
        for (order[0..i]) |prev| {
            if (std.mem.eql(u8, prev, entry)) return "order entries must be unique";
        }
    }
    return null;
}

const EthernetView = struct {
    iface: []const u8,
    ipv4: store_mod.Config.Ipv4,
    dns: []const []const u8,
    generation: u64,
    observedGeneration: u64,
};

fn ethernetResponse(ctx: *router.Context, mgr: *Manager, iface: []const u8) anyerror!router.Response {
    const eth = ctx.store.getEthernet(iface) orelse store_mod.Config.Ethernet{};
    const view: EthernetView = .{
        .iface = iface,
        .ipv4 = eth.ipv4,
        .dns = eth.dns,
        .generation = mgr.gen.load(.acquire),
        .observedGeneration = mgr.observed_gen.load(.acquire),
    };
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, view, .{}) };
}

/// GET /api/v1/network — all interfaces (docs/06 §5.2): observed rtnetlink
/// state merged with lease facts, desired store state, wifi state and the
/// WAN role per interface.
pub fn getNetwork(ctx: *router.Context) anyerror!router.Response {
    const mgr = global orelse return notWired(ctx);
    // Per-request arena (main.zig) owns everything below; link.dump
    // failure degrades to "no observed interfaces" rather than a 500
    // (sandboxed unit builds may deny AF_NETLINK).
    const ifaces = link.dump(ctx.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => &[_]link.Iface{},
    };
    const leases = try readLeases(ctx.allocator, mgr.leases_path);
    const wifi_state: ?wifi_mod.State = if (wifi_mod.global) |w|
        (w.state(ctx.allocator) catch null)
    else
        null;
    const body = try assembleNetworkJson(
        ctx.allocator,
        ifaces,
        leases,
        ctx.store,
        wifi_state,
        mgr.gen.load(.acquire),
        mgr.observed_gen.load(.acquire),
    );
    return .{ .status = 200, .body = body };
}

/// GET /api/v1/network/ethernet/{iface} — desired state (absent entry =
/// DHCP defaults, per the store contract) + generation counters.
pub fn getEthernetIface(ctx: *router.Context) anyerror!router.Response {
    const mgr = global orelse return notWired(ctx);
    const iface = checkIfaceParam(ctx) orelse return badRequest(ctx, "invalid interface name");
    return ethernetResponse(ctx, mgr, iface);
}

/// PUT /api/v1/network/ethernet/{iface} — full replace: strict parse
/// (unknown fields → 400, docs/06 §4), validate, persist, render, reload.
pub fn putEthernetIface(ctx: *router.Context) anyerror!router.Response {
    const mgr = global orelse return notWired(ctx);
    const iface = checkIfaceParam(ctx) orelse return badRequest(ctx, "invalid interface name");
    const eth = std.json.parseFromSliceLeaky(store_mod.Config.Ethernet, ctx.allocator, ctx.request.body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return badRequest(ctx, try std.fmt.allocPrint(
            ctx.allocator,
            "body does not match the ethernet config shape ({t}); unknown fields are rejected (docs/06 §4)",
            .{err},
        )),
    };
    return applyEthernet(ctx, mgr, iface, eth);
}

/// PATCH /api/v1/network/ethernet/{iface} — RFC 7396 JSON Merge Patch
/// against the stored object (or DHCP defaults when absent), then the
/// same validate → persist → render → reload pipeline as PUT.
pub fn patchEthernetIface(ctx: *router.Context) anyerror!router.Response {
    const mgr = global orelse return notWired(ctx);
    const iface = checkIfaceParam(ctx) orelse return badRequest(ctx, "invalid interface name");
    const a = ctx.allocator; // per-request arena: mergePatch may alias both inputs

    const current = ctx.store.getEthernet(iface) orelse store_mod.Config.Ethernet{};
    const current_text = try std.json.Stringify.valueAlloc(a, current, .{});
    const target = std.json.parseFromSliceLeaky(std.json.Value, a, current_text, .{}) catch return error.OutOfMemory;
    const patch = std.json.parseFromSliceLeaky(std.json.Value, a, ctx.request.body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return badRequest(ctx, "body is not valid JSON"),
    };
    const merged = try store_mod.mergePatch(a, target, patch);
    const merged_text = try std.json.Stringify.valueAlloc(a, merged, .{});
    const eth = std.json.parseFromSliceLeaky(store_mod.Config.Ethernet, a, merged_text, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return badRequest(ctx, try std.fmt.allocPrint(
            a,
            "merged document does not match the ethernet config shape ({t}); unknown fields are rejected (docs/06 §4)",
            .{err},
        )),
    };
    return applyEthernet(ctx, mgr, iface, eth);
}

fn applyEthernet(ctx: *router.Context, mgr: *Manager, iface: []const u8, eth: store_mod.Config.Ethernet) anyerror!router.Response {
    if (validateEthernet(eth)) |detail| return badRequest(ctx, detail);
    mgr.setEthernet(iface, eth) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PersistFailed => return persistFailure(ctx),
    };
    // Apply is best-effort AFTER the persist: a render/reload hiccup
    // leaves observedGeneration behind generation, which is exactly the
    // "await convergence" contract (docs/06 §4) — not an HTTP error.
    mgr.applyDhcpcd();
    mgr.applyResolv();
    return ethernetResponse(ctx, mgr, iface);
}

const WanView = struct {
    order: []const []const u8,
    generation: u64,
    observedGeneration: u64,
};

fn wanResponse(ctx: *router.Context, mgr: *Manager) anyerror!router.Response {
    const view: WanView = .{
        .order = ctx.store.getWanOrder(),
        .generation = mgr.gen.load(.acquire),
        .observedGeneration = mgr.observed_gen.load(.acquire),
    };
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, view, .{}) };
}

/// GET /api/v1/network/wan — the ordered interface-class preference.
pub fn getWan(ctx: *router.Context) anyerror!router.Response {
    const mgr = global orelse return notWired(ctx);
    return wanResponse(ctx, mgr);
}

/// PUT /api/v1/network/wan — replace the WAN order; re-render so the
/// dhcpcd metrics (and resolv.conf preference) follow immediately.
pub fn putWan(ctx: *router.Context) anyerror!router.Response {
    const mgr = global orelse return notWired(ctx);
    const Body = struct { order: []const []const u8 };
    const body = std.json.parseFromSliceLeaky(Body, ctx.allocator, ctx.request.body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return badRequest(ctx, try std.fmt.allocPrint(
            ctx.allocator,
            "body must be {{\"order\": [...]}} ({t}); unknown fields are rejected (docs/06 §4)",
            .{err},
        )),
    };
    if (validateWanOrder(body.order)) |detail| return badRequest(ctx, detail);
    mgr.setWanOrder(body.order) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PersistFailed => return persistFailure(ctx),
    };
    mgr.applyDhcpcd();
    mgr.applyResolv();
    return wanResponse(ctx, mgr);
}

// ---- wifi handlers (docs/06 §5.2; mechanism lives in wifi.zig) --------------

fn iwdUnavailable(ctx: *router.Context) router.Response {
    return router.problemResponse(ctx, .{
        .type = "urn:astro:problem:iwd-unavailable",
        .title = "Service Unavailable",
        .status = 503,
        .detail = "the wifi subsystem has no D-Bus connection to iwd",
    });
}

fn noRadio(ctx: *router.Context) router.Response {
    return router.problemResponse(ctx, .{
        .type = "urn:astro:problem:no-radio",
        .title = "Service Unavailable",
        .status = 503,
        .detail = "no wifi radio is present on this device",
    });
}

fn iwdError(ctx: *router.Context) router.Response {
    return router.problemResponse(ctx, .{
        .type = "urn:astro:problem:iwd-error",
        .title = "Bad Gateway",
        .status = 502,
        .detail = "iwd rejected the request",
    });
}

/// Wire view of wifi.State (openapi WifiState): station_state travels as
/// "state"; freq_mhz deliberately absent (recorded spec deviation).
const WifiStateView = struct {
    radio_present: bool,
    powered: bool,
    mode: wifi_mod.Mode,
    state: []const u8,
    connected_ssid: ?[]const u8,
    rssi_dbm: ?i16,
};

/// GET /api/v1/network/wifi — radio/station snapshot. A board without a
/// radio (or iwd down) answers radio_present=false, not an HTTP error.
pub fn getWifi(ctx: *router.Context) anyerror!router.Response {
    const w = wifi_mod.global orelse return notWired(ctx);
    const s = w.state(ctx.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BusUnavailable => return iwdUnavailable(ctx),
        else => return iwdError(ctx),
    };
    const view: WifiStateView = .{
        .radio_present = s.radio_present,
        .powered = s.powered,
        .mode = s.mode,
        .state = s.station_state,
        .connected_ssid = s.connected_ssid,
        .rssi_dbm = s.rssi_dbm,
    };
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, view, .{}) };
}

/// POST /api/v1/network/wifi/scan — 202 + operation ref (docs/06 §4);
/// an in-flight scan is returned idempotently by the backend.
pub fn postWifiScan(ctx: *router.Context) anyerror!router.Response {
    const w = wifi_mod.global orelse return notWired(ctx);
    const id = w.scan() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoRadio => return noRadio(ctx),
        error.BusUnavailable => return iwdUnavailable(ctx),
        else => return iwdError(ctx),
    };
    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"operation\":\"/api/v1/operations/{s}\"}}", .{id});
    return .{ .status = 202, .body = body };
}

/// GET /api/v1/network/wifi/networks — latest scan results (strongest
/// first). No radio degrades to an empty listing, not an error.
pub fn getWifiNetworks(ctx: *router.Context) anyerror!router.Response {
    const w = wifi_mod.global orelse return notWired(ctx);
    const list: []const wifi_mod.NetworkInfo = w.networks(ctx.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoRadio => &.{},
        error.BusUnavailable => return iwdUnavailable(ctx),
        else => return iwdError(ctx),
    };
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, list, .{}) };
}

/// GET /api/v1/network/wifi/connection — configured profile or JSON
/// null; the psk is write-only (openapi WifiConnectionState).
pub fn getWifiConnection(ctx: *router.Context) anyerror!router.Response {
    if (wifi_mod.global == null) return notWired(ctx);
    const conn = ctx.store.getWifiConnection() orelse
        return .{ .status = 200, .body = "null" };
    const View = struct { ssid: []const u8 };
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, View{ .ssid = conn.ssid }, .{}) };
}

/// PUT /api/v1/network/wifi/connection — validate, persist, render the
/// iwd profile, best-effort connect. 202 even when the network is out of
/// range (docs/06 §7: desired state may precede reality); the attempt is
/// narrated by network.wifi.state events.
pub fn putWifiConnection(ctx: *router.Context) anyerror!router.Response {
    const w = wifi_mod.global orelse return notWired(ctx);
    const Body = struct { ssid: []const u8, psk: []const u8 };
    const body = std.json.parseFromSliceLeaky(Body, ctx.allocator, ctx.request.body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return badRequest(ctx, try std.fmt.allocPrint(
            ctx.allocator,
            "body must be {{\"ssid\": ..., \"psk\": ...}} ({t}); unknown fields are rejected (docs/06 §4)",
            .{err},
        )),
    };
    w.connect(body.ssid, body.psk) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArgument => return badRequest(ctx, "ssid must be 1..32 bytes; psk must be a 8..63-char passphrase, 64 hex digits, or empty (open network)"),
        error.StoreFailed => return persistFailure(ctx),
        error.BusUnavailable => return iwdUnavailable(ctx),
        else => return iwdError(ctx),
    };
    return .{ .status = 202, .body = "{\"operation\":null}" };
}

/// DELETE /api/v1/network/wifi/connection — forget (idempotent) → 204.
pub fn deleteWifiConnection(ctx: *router.Context) anyerror!router.Response {
    const w = wifi_mod.global orelse return notWired(ctx);
    w.forget() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StoreFailed => return persistFailure(ctx),
        error.BusUnavailable => return iwdUnavailable(ctx),
        else => return iwdError(ctx),
    };
    return .{ .status = 204, .body = "" };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn testReloadOk() Error!void {
    test_reload_count += 1;
}
var test_reload_count: usize = 0;

fn mkdirForTest(path: []const u8) !void {
    const path_z = posix.toPosixPath(path) catch return error.NameTooLong;
    const rc = linux.mkdirat(linux.AT.FDCWD, &path_z, 0o755);
    if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
}

fn rmdirForTest(path: []const u8) void {
    const path_z = posix.toPosixPath(path) catch return;
    _ = linux.unlinkat(linux.AT.FDCWD, &path_z, linux.AT.REMOVEDIR);
}

fn loadTestStore(path_buf: []u8, comptime suffix: []const u8, doc: []const u8) !store_mod.Store {
    const path = fsutil.testTmpPath(path_buf, suffix);
    try fsutil.writeFileSync(path, doc);
    return store_mod.Store.load(testing.allocator, path);
}

const golden_store_doc =
    \\{"schema": 1,
    \\ "network": {
    \\   "ethernet": {
    \\     "eth0": {"ipv4": {"mode": "static", "address": "192.0.2.10",
    \\              "prefix": 24, "gateway": "192.0.2.1"},
    \\              "dns": ["192.0.2.53"]},
    \\     "eth1": {}
    \\   },
    \\   "wan": {"order": ["ethernet", "wifi"]}
    \\ }}
;

test "renderDhcpcdConf: golden static + dhcp + metric assignment" {
    var path_buf: [128]u8 = undefined;
    var st = try loadTestStore(&path_buf, "netconf-golden.json", golden_store_doc);
    defer st.deinit();
    defer fsutil.unlink(st.path) catch {};

    const conf = try renderDhcpcdConf(testing.allocator, &st);
    defer testing.allocator.free(conf);

    const golden =
        \\# dhcpcd.conf — RENDERED BY ASTROD, DO NOT EDIT (docs/07 §2).
        \\# Desired state lives in /data/config/astro.json (network.*); this
        \\# file is regenerated on astrod startup and on every config change.
        \\# One resolv.conf writer: astrod renders /run/astro/resolv.conf from
        \\# store DNS + the lease exports (hook 60-astro-lease), so dhcpcd's
        \\# own resolv.conf hook stays off in BOTH this and the fallback conf.
        \\nohook resolv.conf
        \\# Send the system hostname to the DHCP server (dhcpcd.conf(5): an
        \\# empty name means the current kernel hostname).
        \\hostname
        \\# chown /run/dhcpcd/sock root:astrod so unprivileged astrod can send
        \\# the rebind command after re-rendering (dhcpcd-10.3.2 control.c).
        \\controlgroup astrod
        \\# AD-015: dhcpcd owns addressing on wired AND wifi — iwd only
        \\# associates (EnableNetworkConfiguration=false).
        \\allowinterfaces eth* wlan*
        \\
        \\# WAN policy (network.wan.order): route preference via metrics,
        \\# lowest wins — never rtnetlink surgery from astrod.
        \\interface eth*
        \\metric 100
        \\interface wlan*
        \\metric 200
        \\
        \\# network.ethernet.eth0
        \\interface eth0
        \\metric 100
        \\static ip_address=192.0.2.10/24
        \\static routers=192.0.2.1
        \\
        \\# network.ethernet.eth1
        \\interface eth1
        \\metric 100
        \\
    ;
    try testing.expectEqualStrings(golden, conf);
}

test "renderDhcpcdConf: wan order flip changes metrics; wifi-first" {
    var path_buf: [128]u8 = undefined;
    var st = try loadTestStore(&path_buf, "netconf-wanflip.json",
        \\{"schema": 1, "network": {"wan": {"order": ["wifi", "ethernet"]}}}
    );
    defer st.deinit();
    defer fsutil.unlink(st.path) catch {};

    const conf = try renderDhcpcdConf(testing.allocator, &st);
    defer testing.allocator.free(conf);
    try testing.expect(std.mem.indexOf(u8, conf, "interface wlan*\nmetric 100\n") != null);
    try testing.expect(std.mem.indexOf(u8, conf, "interface eth*\nmetric 200\n") != null);
    // wlan* must be rendered before eth* (order carries the ranking).
    try testing.expect(std.mem.indexOf(u8, conf, "interface wlan*").? < std.mem.indexOf(u8, conf, "interface eth*").?);
}

test "renderDhcpcdConf: unranked class gets metric 1000, odd names allowed explicitly" {
    var path_buf: [128]u8 = undefined;
    var st = try loadTestStore(&path_buf, "netconf-unranked.json",
        \\{"schema": 1, "network": {
        \\  "ethernet": {"usb0": {}},
        \\  "wan": {"order": ["wifi"]}}}
    );
    defer st.deinit();
    defer fsutil.unlink(st.path) catch {};

    const conf = try renderDhcpcdConf(testing.allocator, &st);
    defer testing.allocator.free(conf);
    // usb0 is "other": explicitly allowed, unranked metric.
    try testing.expect(std.mem.indexOf(u8, conf, "allowinterfaces usb0") != null);
    try testing.expect(std.mem.indexOf(u8, conf, "interface usb0\nmetric 1000\n") != null);
    // ethernet absent from the order: no eth* class block.
    try testing.expect(std.mem.indexOf(u8, conf, "interface eth*") == null);
}

test "renderResolvConf: static beats DHCP, wan preference orders servers, cap 3" {
    var path_buf: [128]u8 = undefined;
    var st = try loadTestStore(&path_buf, "netconf-resolv.json", golden_store_doc);
    defer st.deinit();
    defer fsutil.unlink(st.path) catch {};

    const leases = [_]Lease{
        // eth0 has static DNS in the store — its lease DNS must lose.
        .{ .iface = "eth0", .dns = &.{"10.0.2.3"}, .domain = "lan.example" },
        .{ .iface = "wlan0", .dns = &.{ "9.9.9.9", "149.112.112.112" } },
        .{ .iface = "eth1", .dns = &.{ "10.0.2.3", "10.9.9.1" } },
    };
    const content = try renderResolvConf(testing.allocator, &leases, &st);
    defer testing.allocator.free(content);

    // Preference: eth0 static (192.0.2.53), then eth1 lease (10.0.2.3,
    // 10.9.9.1 — cap reached), wlan0 never contributes. Domain comes from
    // the preferred lease that has one (eth0).
    const tail =
        \\search lan.example
        \\nameserver 192.0.2.53
        \\nameserver 10.0.2.3
        \\nameserver 10.9.9.1
        \\
    ;
    try testing.expect(std.mem.endsWith(u8, content, tail));
    try testing.expect(std.mem.indexOf(u8, content, "9.9.9.9") == null);
}

test "renderResolvConf: wifi-first order prefers the wlan lease and dedupes" {
    var path_buf: [128]u8 = undefined;
    var st = try loadTestStore(&path_buf, "netconf-resolv2.json",
        \\{"schema": 1, "network": {"wan": {"order": ["wifi", "ethernet"]}}}
    );
    defer st.deinit();
    defer fsutil.unlink(st.path) catch {};

    const leases = [_]Lease{
        .{ .iface = "eth0", .dns = &.{ "10.0.2.3", "9.9.9.9" }, .domain = "wired.example" },
        .{ .iface = "wlan0", .dns = &.{"9.9.9.9"}, .domain = "wifi.example" },
    };
    const content = try renderResolvConf(testing.allocator, &leases, &st);
    defer testing.allocator.free(content);
    const tail =
        \\search wifi.example
        \\nameserver 9.9.9.9
        \\nameserver 10.0.2.3
        \\
    ;
    try testing.expect(std.mem.endsWith(u8, content, tail));
}

test "parseLease: hook-shaped document round-trips; garbage rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Exactly what dhcpcd-hook.sh emits for a BOUND with full facts.
    const lease = try parseLease(arena,
        \\{"iface": "eth0", "reason": "BOUND", "dns": ["10.0.2.3", "9.9.9.9"],
        \\ "domain": "lan.example", "address": "10.0.2.15", "prefix": 24,
        \\ "gateway": "10.0.2.2", "ts": 1752969600}
    );
    try testing.expectEqualStrings("eth0", lease.iface);
    try testing.expectEqual(@as(usize, 2), lease.dns.len);
    try testing.expectEqualStrings("10.0.2.3", lease.dns[0]);
    try testing.expectEqualStrings("lan.example", lease.domain.?);
    try testing.expectEqualStrings("10.0.2.15", lease.address.?);
    try testing.expectEqual(@as(u8, 24), lease.prefix.?);
    try testing.expectEqualStrings("10.0.2.2", lease.gateway.?);
    try testing.expectEqual(@as(i64, 1752969600), lease.ts.?);

    // Minimal document (v6 reasons omit most facts).
    const minimal = try parseLease(arena,
        \\{"iface": "wlan0", "reason": "BOUND6", "dns": []}
    );
    try testing.expectEqualStrings("wlan0", minimal.iface);
    try testing.expectEqual(@as(usize, 0), minimal.dns.len);
    try testing.expect(minimal.address == null);

    try testing.expectError(error.InvalidLease, parseLease(arena, "{}"));
    try testing.expectError(error.InvalidLease, parseLease(arena, "not json"));
    try testing.expectError(error.InvalidLease, parseLease(arena,
        \\{"iface": "../etc", "dns": []}
    ));
}

test "writeRendered: replaces a bootstrap symlink with a real file, no litter" {
    var target_buf: [128]u8 = undefined;
    var link_buf: [128]u8 = undefined;
    const target = fsutil.testTmpPath(&target_buf, "netconf-fallback.conf");
    const link_path = fsutil.testTmpPath(&link_buf, "netconf-rendered.conf");
    try fsutil.writeFileSync(target, "fallback content\n");
    defer fsutil.unlink(target) catch {};
    defer fsutil.unlink(link_path) catch {};

    // Simulate the tmpfiles bootstrap: rendered path starts as a symlink.
    const target_z = try posix.toPosixPath(target);
    const link_z = try posix.toPosixPath(link_path);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.symlinkat(&target_z, linux.AT.FDCWD, &link_z)));

    try writeRendered(link_path, "rendered content\n");

    // The rendered path is now a regular file with the new content …
    const got = try fsutil.readFileAlloc(testing.allocator, link_path, 1024);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("rendered content\n", got);
    // … the fallback target was NOT written through …
    const fb = try fsutil.readFileAlloc(testing.allocator, target, 1024);
    defer testing.allocator.free(fb);
    try testing.expectEqualStrings("fallback content\n", fb);
    // … and no .tmp litter remains.
    var tmp_buf: [140]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{link_path});
    try testing.expect(!fsutil.exists(tmp));
    // A regular file, not a symlink: re-resolving must not find a link.
    var stx: linux.Statx = undefined;
    const lp_z = try posix.toPosixPath(link_path);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.statx(linux.AT.FDCWD, &lp_z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx)));
    try testing.expect(stx.mode & linux.S.IFMT == linux.S.IFREG);
}

test "readLeases: missing dir is empty; files parse; junk skipped" {
    var dir_buf: [128]u8 = undefined;
    const dir = fsutil.testTmpPath(&dir_buf, "netconf-leases");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const empty = try readLeases(arena, dir);
    try testing.expectEqual(@as(usize, 0), empty.len);

    try mkdirForTest(dir);
    defer rmdirForTest(dir);
    var f1: [160]u8 = undefined;
    const lease_path = try std.fmt.bufPrint(&f1, "{s}/eth0.json", .{dir});
    try fsutil.writeFileSync(lease_path,
        \\{"iface": "eth0", "dns": ["10.0.2.3"], "ts": 1}
    );
    defer fsutil.unlink(lease_path) catch {};
    var f2: [160]u8 = undefined;
    const junk_path = try std.fmt.bufPrint(&f2, "{s}/torn.json", .{dir});
    try fsutil.writeFileSync(junk_path, "{\"iface\": \"eth");
    defer fsutil.unlink(junk_path) catch {};
    var f3: [160]u8 = undefined;
    const other_path = try std.fmt.bufPrint(&f3, "{s}/README", .{dir});
    try fsutil.writeFileSync(other_path, "not a lease");
    defer fsutil.unlink(other_path) catch {};

    const leases = try readLeases(arena, dir);
    try testing.expectEqual(@as(usize, 1), leases.len);
    try testing.expectEqualStrings("eth0", leases[0].iface);
    try testing.expectEqualStrings("10.0.2.3", leases[0].dns[0]);
}

test "LeaseWatcher: rename-in and delete produce events" {
    var dir_buf: [128]u8 = undefined;
    const dir = fsutil.testTmpPath(&dir_buf, "netconf-watch");
    try mkdirForTest(dir);
    defer rmdirForTest(dir);

    const Capture = struct {
        var count: std.atomic.Value(u32) = .init(0);
        var last_removed: std.atomic.Value(bool) = .init(false);
        fn handle(_: ?*anyopaque, event: LeaseEvent) void {
            if (!std.mem.eql(u8, event.iface(), "eth0")) return;
            last_removed.store(event.removed, .release);
            _ = count.fetchAdd(1, .acq_rel);
        }
        fn waitFor(want: u32) bool {
            var spins: usize = 0;
            while (spins < 400) : (spins += 1) {
                if (count.load(.acquire) >= want) return true;
                sync.sleepMs(5);
            }
            return false;
        }
    };
    Capture.count.store(0, .release);

    const w = try LeaseWatcher.init(testing.allocator, dir, Capture.handle, null);
    defer w.deinit();
    try w.start();

    // The hook's atomic pattern: write tmp, then rename → IN_MOVED_TO.
    var tmp_buf: [160]u8 = undefined;
    var dst_buf: [160]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/.eth0.tmp", .{dir});
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/eth0.json", .{dir});
    try fsutil.writeFileSync(tmp, "{\"iface\": \"eth0\", \"dns\": []}");
    try fsutil.rename(tmp, dst);
    try testing.expect(Capture.waitFor(1));
    try testing.expect(!Capture.last_removed.load(.acquire));

    try fsutil.unlink(dst);
    try testing.expect(Capture.waitFor(2));
    try testing.expect(Capture.last_removed.load(.acquire));
}

// -- handler-level tests (Manager wired to scratch paths + stub reload) -------

const HandlerRig = struct {
    st: store_mod.Store,
    mgr: *Manager,
    store_path_buf: [128]u8 = undefined,
    conf_buf: [128]u8 = undefined,
    resolv_buf: [128]u8 = undefined,
    leases_buf: [128]u8 = undefined,

    fn init(self: *HandlerRig, comptime tag: []const u8, doc: []const u8) !void {
        const store_path = fsutil.testTmpPath(&self.store_path_buf, tag ++ "-store.json");
        try fsutil.writeFileSync(store_path, doc);
        self.st = try store_mod.Store.load(testing.allocator, store_path);
        errdefer self.st.deinit();
        self.mgr = try Manager.init(testing.allocator, &self.st, null);
        self.mgr.conf_path = fsutil.testTmpPath(&self.conf_buf, tag ++ "-dhcpcd.conf");
        self.mgr.resolv_path = fsutil.testTmpPath(&self.resolv_buf, tag ++ "-resolv.conf");
        self.mgr.leases_path = fsutil.testTmpPath(&self.leases_buf, tag ++ "-leases");
        self.mgr.reload_fn = testReloadOk;
        global = self.mgr;
    }

    fn deinit(self: *HandlerRig) void {
        global = null;
        fsutil.unlink(self.mgr.conf_path) catch {};
        fsutil.unlink(self.mgr.resolv_path) catch {};
        fsutil.unlink(self.st.path) catch {};
        self.mgr.deinit();
        self.st.deinit();
    }

    fn ctx(self: *HandlerRig, arena: std.mem.Allocator, method: router.Method, path: []const u8, body: []const u8) router.Context {
        return .{
            .allocator = arena,
            .store = &self.st,
            .request = .{ .method = method, .path = path, .body = body },
        };
    }
};

test "PUT /network/ethernet/{iface}: persist → render → reload → 200 with generations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rig: HandlerRig = .{ .st = undefined, .mgr = undefined };
    try rig.init("netconf-put", "{\"schema\": 1}");
    defer rig.deinit();
    const reloads_before = test_reload_count;

    var put_ctx = rig.ctx(arena, .PUT, "/api/v1/network/ethernet/eth0",
        \\{"ipv4": {"mode": "static", "address": "192.0.2.10", "prefix": 24,
        \\ "gateway": "192.0.2.1"}, "dns": ["192.0.2.53"]}
    );
    // Routes still point at networkPending until the router followup, so
    // the handler is exercised directly with the param bound by hand.
    put_ctx.param = "eth0";
    const direct = try putEthernetIface(&put_ctx);
    try testing.expectEqual(@as(u16, 200), direct.status);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, direct.body, .{});
    try testing.expectEqualStrings("eth0", parsed.object.get("iface").?.string);
    try testing.expectEqualStrings("static", parsed.object.get("ipv4").?.object.get("mode").?.string);
    // One mutation: generation 2, converged (stub reload succeeded).
    try testing.expectEqual(@as(i64, 2), parsed.object.get("generation").?.integer);
    try testing.expectEqual(@as(i64, 2), parsed.object.get("observedGeneration").?.integer);
    try testing.expect(test_reload_count > reloads_before);

    // The store persisted (fresh load sees the entry) …
    var st2 = try store_mod.Store.load(testing.allocator, rig.st.path);
    defer st2.deinit();
    try testing.expectEqualStrings("192.0.2.10", st2.getEthernet("eth0").?.ipv4.address.?);
    // … and the rendered file carries the static block.
    const conf = try fsutil.readFileAlloc(testing.allocator, rig.mgr.conf_path, 64 * 1024);
    defer testing.allocator.free(conf);
    try testing.expect(std.mem.indexOf(u8, conf, "static ip_address=192.0.2.10/24") != null);
    try testing.expect(std.mem.indexOf(u8, conf, "static routers=192.0.2.1") != null);

    // GET reflects the stored object.
    var get_ctx = rig.ctx(arena, .GET, "/api/v1/network/ethernet/eth0", "");
    get_ctx.param = "eth0";
    const got = try getEthernetIface(&get_ctx);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "192.0.2.10") != null);
}

test "PUT /network/ethernet: unknown fields, bad shapes and bad names are 400" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rig: HandlerRig = .{ .st = undefined, .mgr = undefined };
    try rig.init("netconf-400", "{\"schema\": 1}");
    defer rig.deinit();

    const cases = [_][]const u8{
        "{\"ipv4\": {\"mode\": \"dhcp\"}, \"bogus\": 1}", // unknown field (docs/06 §4)
        "{\"ipv4\": {\"mode\": \"static\"}}", // static without address
        "{\"ipv4\": {\"mode\": \"static\", \"address\": \"not-an-ip\", \"prefix\": 24}}",
        "{\"ipv4\": {\"mode\": \"static\", \"address\": \"192.0.2.10\", \"prefix\": 33}}",
        "{\"ipv4\": {\"mode\": \"dhcp\", \"address\": \"192.0.2.10\"}}", // static field under dhcp
        "{\"ipv4\": {\"mode\": \"magic\"}}",
        "{\"dns\": [\"nine.nine.nine.nine\"]}",
    };
    for (cases) |body| {
        var c = rig.ctx(arena, .PUT, "/api/v1/network/ethernet/eth0", body);
        c.param = "eth0";
        const resp = try putEthernetIface(&c);
        try testing.expectEqual(@as(u16, 400), resp.status);
    }

    var bad_name = rig.ctx(arena, .PUT, "/api/v1/network/ethernet/../etc", "{}");
    bad_name.param = "../etc";
    try testing.expectEqual(@as(u16, 400), (try putEthernetIface(&bad_name)).status);
}

test "PATCH /network/ethernet/{iface}: merge-into-static then null-reset to dhcp" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rig: HandlerRig = .{ .st = undefined, .mgr = undefined };
    try rig.init("netconf-patch", golden_store_doc);
    defer rig.deinit();

    // Patch dns only — the static ipv4 block must survive the merge.
    var c1 = rig.ctx(arena, .PATCH, "/api/v1/network/ethernet/eth0",
        \\{"dns": ["9.9.9.9"]}
    );
    c1.param = "eth0";
    const r1 = try patchEthernetIface(&c1);
    try testing.expectEqual(@as(u16, 200), r1.status);
    try testing.expect(std.mem.indexOf(u8, r1.body, "\"9.9.9.9\"") != null);
    try testing.expect(std.mem.indexOf(u8, r1.body, "192.0.2.10") != null);

    // Null-reset back to plain DHCP (RFC 7396 null deletes).
    var c2 = rig.ctx(arena, .PATCH, "/api/v1/network/ethernet/eth0",
        \\{"ipv4": {"mode": "dhcp", "address": null, "prefix": null,
        \\ "gateway": null}, "dns": null}
    );
    c2.param = "eth0";
    const r2 = try patchEthernetIface(&c2);
    try testing.expectEqual(@as(u16, 200), r2.status);
    try testing.expect(std.mem.indexOf(u8, r2.body, "\"mode\":\"dhcp\"") != null);
    try testing.expect(std.mem.indexOf(u8, r2.body, "192.0.2.10") == null);
    const conf = try fsutil.readFileAlloc(testing.allocator, rig.mgr.conf_path, 64 * 1024);
    defer testing.allocator.free(conf);
    try testing.expect(std.mem.indexOf(u8, conf, "static ip_address") == null);

    // A patch that merges into an invalid document is a 400.
    var c3 = rig.ctx(arena, .PATCH, "/api/v1/network/ethernet/eth0",
        \\{"ipv4": {"mode": "static"}}
    );
    c3.param = "eth0";
    try testing.expectEqual(@as(u16, 400), (try patchEthernetIface(&c3)).status);
}

test "GET/PUT /network/wan: validation, persistence, metric re-render" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rig: HandlerRig = .{ .st = undefined, .mgr = undefined };
    try rig.init("netconf-wan", "{\"schema\": 1}");
    defer rig.deinit();

    var get_ctx = rig.ctx(arena, .GET, "/api/v1/network/wan", "");
    const got = try getWan(&get_ctx);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"ethernet\",\"wifi\"") != null);

    const bad_bodies = [_][]const u8{
        "{\"order\": []}",
        "{\"order\": [\"ethernet\", \"ethernet\"]}",
        "{\"order\": [\"cellular\"]}",
        "{\"order\": [\"wifi\"], \"bogus\": true}",
        "not json",
    };
    for (bad_bodies) |body| {
        var c = rig.ctx(arena, .PUT, "/api/v1/network/wan", body);
        try testing.expectEqual(@as(u16, 400), (try putWan(&c)).status);
    }

    var put_ctx = rig.ctx(arena, .PUT, "/api/v1/network/wan", "{\"order\": [\"wifi\", \"ethernet\"]}");
    const put = try putWan(&put_ctx);
    try testing.expectEqual(@as(u16, 200), put.status);
    try testing.expect(std.mem.indexOf(u8, put.body, "\"wifi\",\"ethernet\"") != null);

    var st2 = try store_mod.Store.load(testing.allocator, rig.st.path);
    defer st2.deinit();
    try testing.expectEqualStrings("wifi", st2.getWanOrder()[0]);
    const conf = try fsutil.readFileAlloc(testing.allocator, rig.mgr.conf_path, 64 * 1024);
    defer testing.allocator.free(conf);
    try testing.expect(std.mem.indexOf(u8, conf, "interface wlan*\nmetric 100\n") != null);
    try testing.expect(std.mem.indexOf(u8, conf, "interface eth*\nmetric 200\n") != null);
}

test "assembleNetworkJson: the GET /network merge shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var path_buf: [128]u8 = undefined;
    var st = try loadTestStore(&path_buf, "netconf-assemble.json", golden_store_doc);
    defer st.deinit();
    defer fsutil.unlink(st.path) catch {};

    var eth0: link.Iface = .{ .index = 2, .up = true, .carrier = true, .has_mac = true, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 } };
    @memcpy(eth0.name_buf[0..4], "eth0");
    eth0.name_len = 4;
    var v4: link.Addr = .{ .family = posix.AF.INET, .prefix = 24, .bytes = @splat(0) };
    @memcpy(v4.bytes[0..4], &[4]u8{ 10, 0, 2, 15 });
    var eth0_addrs = [_]link.Addr{v4};
    eth0.addrs = &eth0_addrs;
    var wlan0: link.Iface = .{ .index = 3 };
    @memcpy(wlan0.name_buf[0..5], "wlan0");
    wlan0.name_len = 5;
    var lo: link.Iface = .{ .index = 1, .up = true };
    @memcpy(lo.name_buf[0..2], "lo");
    lo.name_len = 2;

    const leases = [_]Lease{
        .{ .iface = "eth0", .dns = &.{"10.0.2.3"}, .domain = "lan.example", .address = "10.0.2.15", .prefix = 24, .gateway = "10.0.2.2" },
    };
    const wifi_state: wifi_mod.State = .{
        .radio_present = true,
        .powered = true,
        .mode = .station,
        .connected_ssid = "astro-test",
        .rssi_dbm = -48,
        .station_state = "connected",
    };

    const body = try assembleNetworkJson(arena, &.{ lo, eth0, wlan0 }, &leases, &st, wifi_state, 3, 2);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const root = parsed.object;

    try testing.expectEqual(@as(i64, 3), root.get("generation").?.integer);
    try testing.expectEqual(@as(i64, 2), root.get("observedGeneration").?.integer);
    try testing.expectEqualStrings("ethernet", root.get("wan").?.object.get("order").?.array.items[0].string);

    const ifaces = root.get("interfaces").?.array.items;
    try testing.expectEqual(@as(usize, 2), ifaces.len); // lo filtered out

    const e = ifaces[0].object;
    try testing.expectEqualStrings("eth0", e.get("name").?.string);
    try testing.expectEqualStrings("ethernet", e.get("type").?.string);
    try testing.expectEqualStrings("52:54:00:12:34:56", e.get("mac").?.string);
    try testing.expect(e.get("up").?.bool);
    try testing.expect(e.get("carrier").?.bool);
    try testing.expectEqualStrings("10.0.2.15/24", e.get("addresses").?.array.items[0].string);
    try testing.expectEqualStrings("primary", e.get("wan_role").?.string);
    try testing.expectEqualStrings("static", e.get("config").?.object.get("ipv4").?.object.get("mode").?.string);
    try testing.expectEqualStrings("10.0.2.2", e.get("lease").?.object.get("gateway").?.string);
    try testing.expectEqualStrings("lan.example", e.get("lease").?.object.get("domain").?.string);

    const w = ifaces[1].object;
    try testing.expectEqualStrings("wifi", w.get("type").?.string);
    try testing.expectEqualStrings("secondary", w.get("wan_role").?.string);
    try testing.expectEqual(@as(i64, -48), w.get("rssi_dbm").?.integer);
    try testing.expect(w.get("config").? == .null);
    try testing.expect(w.get("lease").? == .null);

    try testing.expectEqualStrings("connected", root.get("wifi").?.object.get("station_state").?.string);
    try testing.expectEqualStrings("station", root.get("wifi").?.object.get("mode").?.string);
}

test "GET /network via handler: wired manager serves 200; unwired is 501" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Unwired (global == null): 501 problem, matching the router's
    // pre-followup behavior for the whole group.
    var st0 = try store_mod.Store.load(testing.allocator, "/nonexistent/astro.json");
    defer st0.deinit();
    var unwired: router.Context = .{ .allocator = arena, .store = &st0, .request = .{ .method = .GET, .path = "/api/v1/network" } };
    const cold = try getNetwork(&unwired);
    try testing.expectEqual(@as(u16, 501), cold.status);
    try testing.expect(std.mem.indexOf(u8, cold.body, "urn:astro:problem:not-implemented") != null);

    var rig: HandlerRig = .{ .st = undefined, .mgr = undefined };
    try rig.init("netconf-getnet", golden_store_doc);
    defer rig.deinit();

    var c = rig.ctx(arena, .GET, "/api/v1/network", "");
    const resp = try getNetwork(&c);
    try testing.expectEqual(@as(u16, 200), resp.status);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
    // Observed interfaces depend on the environment (may be empty in a
    // netlink-denied sandbox) — the document shape does not.
    try testing.expect(parsed.object.get("interfaces") != null);
    try testing.expect(parsed.object.get("wan") != null);
    try testing.expect(parsed.object.get("generation") != null);
    try testing.expect(parsed.object.get("wifi").? == .null); // no wifi backend in unit builds
}

test "Manager end-to-end: lease export → resolv re-render + observed-state event" {
    var rig: HandlerRig = .{ .st = undefined, .mgr = undefined };
    try rig.init("netconf-e2e", "{\"schema\": 1}");
    defer rig.deinit();
    try mkdirForTest(rig.mgr.leases_path);
    defer rmdirForTest(rig.mgr.leases_path);

    var bus = events_mod.EventBus.init(testing.allocator);
    defer bus.deinit();
    rig.mgr.event_bus = &bus;
    rig.mgr.start(); // initial render + reload (stub) + watcher

    const sub = try bus.subscribe(null);
    defer sub.cancel();

    // The hook's atomic export pattern.
    var tmp_buf: [160]u8 = undefined;
    var dst_buf: [160]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/.eth0.tmp", .{rig.mgr.leases_path});
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/eth0.json", .{rig.mgr.leases_path});
    try fsutil.writeFileSync(tmp,
        \\{"iface": "eth0", "dns": ["10.0.2.3"], "domain": "lan.example", "ts": 1}
    );
    try fsutil.rename(tmp, dst);
    defer fsutil.unlink(dst) catch {};

    const ev = (try sub.next(3000)) orelse return error.NoLeaseEvent;
    try testing.expectEqualStrings(event_ethernet_state, ev.event_type);
    try testing.expect(std.mem.indexOf(u8, ev.payload, "\"iface\":\"eth0\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.payload, "\"bound\":true") != null);

    // onLeaseEvent re-renders resolv BEFORE publishing, so the file is
    // ready once the event arrives.
    const resolv = try fsutil.readFileAlloc(testing.allocator, rig.mgr.resolv_path, 4096);
    defer testing.allocator.free(resolv);
    try testing.expect(std.mem.indexOf(u8, resolv, "search lan.example") != null);
    try testing.expect(std.mem.indexOf(u8, resolv, "nameserver 10.0.2.3") != null);

    // Stop the watcher before the event bus goes away (deinit order).
    if (rig.mgr.watcher) |w| {
        w.deinit();
        rig.mgr.watcher = null;
    }
}

test "validators: iface names, ipv4 literals, wan orders" {
    try testing.expect(validIfaceName("eth0"));
    try testing.expect(validIfaceName("wlan0"));
    try testing.expect(validIfaceName("br-lan.42"));
    try testing.expect(!validIfaceName(""));
    try testing.expect(!validIfaceName("a-name-longer-than-15"));
    try testing.expect(!validIfaceName("../etc"));
    try testing.expect(!validIfaceName("eth 0"));
    try testing.expect(!validIfaceName("eth0/../x"));

    try testing.expect(parseIpv4("192.0.2.10") != null);
    try testing.expect(parseIpv4("0.0.0.0") != null);
    try testing.expect(parseIpv4("255.255.255.255") != null);
    try testing.expect(parseIpv4("256.0.0.1") == null);
    try testing.expect(parseIpv4("1.2.3") == null);
    try testing.expect(parseIpv4("1.2.3.4.5") == null);
    try testing.expect(parseIpv4("1.2.3.x") == null);
    try testing.expect(isIpLiteral("2620:fe::fe"));
    try testing.expect(!isIpLiteral("dns.example"));

    try testing.expect(validateWanOrder(&.{ "ethernet", "wifi" }) == null);
    try testing.expect(validateWanOrder(&.{"wifi"}) == null);
    try testing.expect(validateWanOrder(&.{}) != null);
    try testing.expect(validateWanOrder(&.{ "wifi", "wifi" }) != null);
    try testing.expect(validateWanOrder(&.{"cellular"}) != null);
}
