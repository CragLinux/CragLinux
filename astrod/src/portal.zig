//! AP captive-portal pieces (docs/07 §4 items 2–3, M3 phase 4):
//!
//!  - the embedded provisioning page (@embedFile, self-contained HTML)
//!    and the OS captive-probe redirects — registered in
//!    router.portal_routes and served ON THE AP SURFACE ONLY;
//!  - the DNS catch-all responder: while AP mode is up it answers EVERY
//!    A query with the AP address so phones open the portal. It binds
//!    UDP 5354 on the AP address — NOT 5353 (that is mDNS, a different
//!    protocol and socket) and NOT 53 (astrod is capless; the root
//!    nftables oneshot pair astro-portal-redirect-{start,stop} redirects
//!    AP-interface :53 → :5354 and :80 → :8080, see boards/common
//!    overlay usr/lib/astro/portal-redirect-up.sh);
//!  - the ApController: the enterAp/leaveAp effect implementations the
//!    provisioning machine (provision.zig Effects) executes — profile
//!    render + iwd AP start (wifi.zig), the root nft redirect pair (via
//!    the dinit client), the DNS catch-all, and main's AP HTTP listener,
//!    in that order (reversed on leave).
//!
//! Privileged-port story (baked decision): phones probe http://…:80 and
//! DNS :53; astrod stays capless, so a root nft redirect pair — driven
//! through the existing dinit client around AP up/down — owns ports
//! <1024. Nothing in this module ever needs privilege.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const router = @import("router.zig");
const wifi = @import("wifi.zig");
const dinit = @import("dinit.zig");

/// The AP provisioning subnet (docs/07 §4: iwd's built-in DHCP server
/// serves it from the rendered AP profile's [IPv4] settings).
pub const ap_subnet = "192.168.223.0/24";
/// astrod on the AP interface (profile [IPv4].Address).
pub const ap_addr = [4]u8{ 192, 168, 223, 1 };
/// DNS catch-all port (unprivileged; nft redirects :53 here).
pub const dns_port: u16 = 5354;
/// Portal HTTP listener (nft redirects :80 here) — the AP-surface
/// listener astrod binds on 192.168.223.1 while AP mode is up.
pub const http_port: u16 = 8080;

/// The provisioning page (docs/06 §2 "embedded provisioning UI"):
/// ONE self-contained HTML document, inline CSS/JS, no external assets.
pub const page = @embedFile("portal.html");

/// OS captive-portal probe paths (docs/07 §4 item 3): Android,
/// Apple, Windows (2×). All 302 to the portal page so the OS pops it.
pub const probe_paths = [_][]const u8{
    "/generate_204", // Android
    "/hotspot-detect.html", // iOS/macOS
    "/connecttest.txt", // Windows NCSI (new)
    "/ncsi.txt", // Windows NCSI (legacy)
};

/// GET / on the AP surface: the portal page.
pub fn getPortalPage(_: *router.Context) anyerror!router.Response {
    return .{ .status = 200, .content_type = "text/html; charset=utf-8", .body = page };
}

/// Probe paths on the AP surface: 302 to the portal so phones auto-open
/// it (a non-204/expected answer marks the network "captive").
pub fn probeRedirect(_: *router.Context) anyerror!router.Response {
    return .{ .status = 302, .location = "/", .body = "" };
}

pub const Error = error{
    OutOfMemory,
    NotImplemented,
    /// The datagram is not a plain single-question DNS query (truncated,
    /// a response, a non-QUERY opcode, or compression-pointer labels).
    /// The responder drops it — never answers garbage with garbage.
    Malformed,
    /// Socket setup failed (address not present yet, port taken, fd
    /// limits). enterAp treats it as degraded: the portal still works by
    /// IP; only the DNS-based auto-open is lost.
    BindFailed,
};

// ---- minimal DNS codec (RFC 1035 §4, pure, unit-tested) ---------------------
//
// Scope is exactly the captive catch-all: single-question QUERY-opcode
// datagrams in, single-A-answer datagrams out. Responses echo the
// question and repeat the name VERBATIM — no compression pointers, ever
// (pinned by test): 16 extra bytes buys immunity from the classic
// pointer-handling bug class. EDNS additionals in queries are ignored
// (ARCOUNT is answered as 0); TCP fallback does not exist on this
// surface (answers are ≤ question + 16 bytes, far under 512).

/// Answer TTL: deliberately tiny — after the AP→station flip the same
/// names must re-resolve through real DNS, not a cached 192.168.223.1.
pub const dns_ttl: u32 = 10;

pub const DnsQuestion = struct {
    id: u16,
    /// RD flag from the query (echoed into the response).
    rd: bool,
    /// Question-section bytes: name + qtype + qclass.
    section: []const u8,
    /// Encoded name only, including the terminating zero label.
    name: []const u8,
    qtype: u16,
    qclass: u16,
};

fn readU16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .big);
}

/// Parse one DNS query datagram down to its first question. Anything
/// that is not a plain QUERY with ≥1 question and an uncompressed,
/// in-bounds name is Malformed (drop — misbehaving clients get silence,
/// which is what a lost UDP packet looks like anyway).
pub fn parseQuery(query: []const u8) error{Malformed}!DnsQuestion {
    if (query.len < 12) return error.Malformed;
    const flags = readU16(query, 2);
    if (flags & 0x8000 != 0) return error.Malformed; // QR=1: a response
    if ((flags >> 11) & 0xF != 0) return error.Malformed; // opcode != QUERY
    if (readU16(query, 4) < 1) return error.Malformed; // QDCOUNT 0
    var i: usize = 12;
    while (true) {
        if (i >= query.len) return error.Malformed;
        const l = query[i];
        if (l == 0) {
            i += 1;
            break;
        }
        // 0xC0 = compression pointer (illegal in the first name of a
        // query we accept), 0x40/0x80 = obsolete label types.
        if (l & 0xC0 != 0) return error.Malformed;
        i += 1 + @as(usize, l);
        if (i > query.len or i - 12 > 255) return error.Malformed;
    }
    if (i + 4 > query.len) return error.Malformed;
    return .{
        .id = readU16(query, 0),
        .rd = flags & 0x0100 != 0,
        .name = query[12..i],
        .section = query[12 .. i + 4],
        .qtype = readU16(query, i),
        .qclass = readU16(query, i + 2),
    };
}

/// Build the catch-all answer for one query datagram: echo id/RD/question,
/// QR|AA|RA set, RCODE 0, and — for IN-class A (or ANY) questions — one A
/// record = `answer_addr` (docs/07 §4 item 3 "answers all DNS with
/// itself"). Other qtypes (AAAA…) get an EMPTY NOERROR answer, never
/// NXDOMAIN: every name "exists" so clients immediately fall back to A.
pub fn buildDnsAnswer(
    allocator: std.mem.Allocator,
    query: []const u8,
    answer_addr: [4]u8,
) error{ OutOfMemory, Malformed }![]u8 {
    const q = try parseQuery(query);
    const answer = (q.qclass == 1 or q.qclass == 255) and (q.qtype == 1 or q.qtype == 255);
    const an_len: usize = if (answer) q.name.len + 14 else 0;
    const out = try allocator.alloc(u8, 12 + q.section.len + an_len);
    errdefer allocator.free(out);

    std.mem.writeInt(u16, out[0..2], q.id, .big);
    const flags: u16 = 0x8480 | @as(u16, if (q.rd) 0x0100 else 0); // QR|AA|RA, RD echoed
    std.mem.writeInt(u16, out[2..4], flags, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big); // QDCOUNT
    std.mem.writeInt(u16, out[6..8], if (answer) 1 else 0, .big); // ANCOUNT
    std.mem.writeInt(u16, out[8..10], 0, .big); // NSCOUNT
    std.mem.writeInt(u16, out[10..12], 0, .big); // ARCOUNT (EDNS dropped)
    @memcpy(out[12..][0..q.section.len], q.section);

    if (answer) {
        var off: usize = 12 + q.section.len;
        @memcpy(out[off..][0..q.name.len], q.name); // full name, pointer-free
        off += q.name.len;
        std.mem.writeInt(u16, out[off..][0..2], 1, .big); // TYPE A
        std.mem.writeInt(u16, out[off + 2 ..][0..2], 1, .big); // CLASS IN
        std.mem.writeInt(u32, out[off + 4 ..][0..4], dns_ttl, .big);
        std.mem.writeInt(u16, out[off + 8 ..][0..2], 4, .big); // RDLENGTH
        @memcpy(out[off + 10 ..][0..4], &answer_addr);
    }
    return out;
}

/// DNS catch-all responder. Lifecycle: init → start when the AP comes up
/// (bind bind_addr:port, spawn the answer loop) → stop when the AP goes
/// down → deinit. Active ONLY while AP mode is up.
pub const DnsCatchAll = struct {
    allocator: std.mem.Allocator,
    bind_addr: [4]u8,
    answer_addr: [4]u8,
    /// Overridable for tests (0 = kernel-assigned, see bound_port).
    port: u16 = dns_port,
    running: bool = false,
    fd: posix.fd_t = -1,
    wake_fd: posix.fd_t = -1,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    /// The port actually bound (== port unless port was 0).
    bound_port: u16 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        bind_addr: [4]u8,
        answer_addr: [4]u8,
    ) error{OutOfMemory}!*DnsCatchAll {
        const self = try allocator.create(DnsCatchAll);
        self.* = .{ .allocator = allocator, .bind_addr = bind_addr, .answer_addr = answer_addr };
        return self;
    }

    pub fn deinit(self: *DnsCatchAll) void {
        self.stop();
        self.allocator.destroy(self);
    }

    /// Bind UDP bind_addr:port and spawn the answer loop. Idempotent
    /// while running.
    pub fn start(self: *DnsCatchAll) Error!void {
        if (self.running) return;
        const fd = udpSocket() orelse return Error.BindFailed;
        errdefer _ = linux.close(fd);
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
        // IP_FREEBIND (ip(7), value 15): the AP address lands only after
        // iwd's netconfig settles StartProfile — binding must not lose
        // that race (same story as main.zig's AP HTTP listener).
        posix.setsockopt(fd, 0, 15, &std.mem.toBytes(@as(c_int, 1))) catch {};
        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = @bitCast(self.bind_addr),
        };
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in))) != .SUCCESS)
            return Error.BindFailed;
        var got: posix.sockaddr.in = undefined;
        var got_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        if (linux.errno(linux.getsockname(fd, @ptrCast(&got), &got_len)) != .SUCCESS)
            return Error.BindFailed;
        self.bound_port = std.mem.bigToNative(u16, got.port);

        const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC);
        if (linux.errno(efd_rc) != .SUCCESS) return Error.BindFailed;
        self.wake_fd = @intCast(efd_rc);
        self.fd = fd;
        self.stop_flag.store(false, .release);
        self.thread = std.Thread.spawn(.{}, loop, .{self}) catch {
            _ = linux.close(self.wake_fd);
            self.wake_fd = -1;
            self.fd = -1;
            return Error.BindFailed; // fd closed by the errdefer
        };
        self.running = true;
    }

    /// Stop the loop and close the sockets. Idempotent.
    pub fn stop(self: *DnsCatchAll) void {
        self.running = false;
        const t = self.thread orelse return;
        self.stop_flag.store(true, .release);
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, @ptrCast(&one), 8);
        t.join();
        self.thread = null;
        _ = linux.close(self.fd);
        _ = linux.close(self.wake_fd);
        self.fd = -1;
        self.wake_fd = -1;
    }

    /// One received query datagram → the answer datagram (pure; the loop
    /// and the unit tests share it).
    pub fn buildAnswer(
        self: *DnsCatchAll,
        allocator: std.mem.Allocator,
        query: []const u8,
    ) Error![]u8 {
        return buildDnsAnswer(allocator, query, self.answer_addr);
    }

    fn loop(self: *DnsCatchAll) void {
        var in_buf: [1500]u8 = undefined;
        var out_buf: [2048]u8 = undefined;
        while (!self.stop_flag.load(.acquire)) {
            var pfds = [_]posix.pollfd{
                .{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&pfds, -1) catch return;
            if (pfds[1].revents & posix.POLL.IN != 0) {
                var eb: [8]u8 = undefined;
                _ = linux.read(self.wake_fd, &eb, 8);
            }
            if (pfds[0].revents & posix.POLL.IN == 0) continue;
            var src: posix.sockaddr.in = undefined;
            var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            const rc = linux.recvfrom(self.fd, &in_buf, in_buf.len, 0, @ptrCast(&src), &src_len);
            if (linux.errno(rc) != .SUCCESS) continue;
            var fba = std.heap.FixedBufferAllocator.init(&out_buf);
            const answer = buildDnsAnswer(fba.allocator(), in_buf[0..rc], self.answer_addr) catch continue;
            _ = linux.sendto(self.fd, answer.ptr, answer.len, 0, @ptrCast(&src), src_len);
        }
    }
};

/// linux.socket with the raw-syscall errno dance (std.posix lost its
/// socket wrappers in 0.16; main.zig's listeners do the same).
fn udpSocket() ?posix.fd_t {
    const rc = linux.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

// ---- the AP controller (provision.Effects enterAp/leaveAp) ------------------

/// Root dinit oneshots wrapping /usr/lib/astro/portal-redirect-{up,down}.sh
/// — the nft :80→8080/:53→5354 redirect pair on the AP interface plus the
/// iwd EnableNetworkConfiguration window swap (astrod is capless; docs/02
/// §7 residual-root-ops pattern).
pub const redirect_start_service = "astro-portal-redirect-start";
pub const redirect_stop_service = "astro-portal-redirect-stop";

/// Composes the full AP window around wifi.zig's radio mechanics:
///
///   enterAp: derive ssid/psk from the machine-id → wifi.apStart (profile
///            render + Mode="ap" + StartProfile) → dinit start
///            astro-portal-redirect-start (root nft + iwd netconfig
///            window) → DNS catch-all up → main's AP listener up.
///   leaveAp: listener down → DNS down → astro-portal-redirect-stop →
///            wifi.apStop (Stop + Mode="station").
///
/// Driven from the provisioning machine's single reconciliation context
/// (provision.Machine is not thread-safe; neither is this). Every step
/// after apStart is best-effort: a missing nft rule or DNS bind failure
/// degrades auto-open, it does not kill the portal.
pub const ApController = struct {
    allocator: std.mem.Allocator,
    /// Borrowed — main owns the machine-id buffer for the daemon's life.
    machine_id: []const u8,
    dinit_socket: []const u8 = dinit.default_socket_path,
    /// Unit tests disable the real UDP catch-all.
    manage_dns: bool = true,
    hooks: Hooks = .{},
    dns: ?*DnsCatchAll = null,
    active: bool = false,
    /// Static strings only; surfaced via GET /system last_error
    /// (redacted view included, portal page displays it). Written under
    /// the provisioning Manager's reconciliation context; HTTP threads
    /// read through lastErrorText()/the atomic tag below.
    last_error: ?[]const u8 = null,
    /// Cross-thread mirror of last_error (a fat ?[]const u8 cannot be
    /// read atomically): request threads load the tag, mapping back to
    /// the same static strings.
    last_error_tag: std.atomic.Value(u8) = .init(0),

    pub const Hooks = struct {
        ctx: ?*anyopaque = null,
        /// Override the wifi backend (scripted tests); null → the real
        /// wifi.global apStart/apStop.
        apStart: ?*const fn (ctx: ?*anyopaque, ssid: []const u8, psk: []const u8) bool = null,
        apStop: ?*const fn (ctx: ?*anyopaque) bool = null,
        /// Override the dinit dispatch (scripted tests); null → the real
        /// dinit.startServiceByName on dinit_socket.
        dinitStart: ?*const fn (ctx: ?*anyopaque, service: []const u8) bool = null,
        /// main.zig's AP HTTP listener (192.168.223.1:http_port) up/down
        /// — the accept loop owns sockets, this controller owns ordering.
        listenerUp: ?*const fn (ctx: ?*anyopaque) void = null,
        listenerDown: ?*const fn (ctx: ?*anyopaque) void = null,
    };

    pub fn init(allocator: std.mem.Allocator, machine_id: []const u8) ApController {
        return .{ .allocator = allocator, .machine_id = machine_id };
    }

    pub fn deinit(self: *ApController) void {
        self.dnsDown();
    }

    const error_texts = [_]?[]const u8{ null, "ap-start-failed", "ap-stop-failed" };

    fn setLastError(self: *ApController, err: ?[]const u8) void {
        self.last_error = err;
        var tag: u8 = 0;
        for (error_texts, 0..) |t, i| {
            if (t != null and err != null and std.mem.eql(u8, t.?, err.?)) tag = @intCast(i);
        }
        self.last_error_tag.store(tag, .release);
    }

    /// Thread-safe last_error read (GET /system on any surface).
    pub fn lastErrorText(self: *const ApController) ?[]const u8 {
        const tag = self.last_error_tag.load(.acquire);
        if (tag >= error_texts.len) return null;
        return error_texts[tag];
    }

    /// provision.Effects.enterAp implementation. Idempotent while active.
    pub fn enterAp(self: *ApController) void {
        if (self.active) return;
        var ssid_buf: [32]u8 = undefined;
        var psk_buf: [16]u8 = undefined;
        const ssid = wifi.deriveApSsid(&ssid_buf, self.machine_id);
        const psk = wifi.deriveApPsk(&psk_buf, self.machine_id);

        if (!self.runApStart(ssid, psk)) {
            self.setLastError("ap-start-failed");
            return; // not active; the next observe retries (provision.zig)
        }
        if (!self.runRedirect(redirect_start_service))
            std.log.warn("portal: {s} dispatch failed (:80/:53 auto-redirect degraded)", .{redirect_start_service});
        if (self.manage_dns) self.dnsUp();
        if (self.hooks.listenerUp) |f| f(self.hooks.ctx);
        self.active = true;
        self.setLastError(null);
    }

    /// provision.Effects.leaveAp implementation. Teardown runs
    /// unconditionally (defensive against effect/reality drift) and is
    /// idempotent end to end.
    pub fn leaveAp(self: *ApController) void {
        if (self.hooks.listenerDown) |f| f(self.hooks.ctx);
        self.dnsDown();
        if (!self.runRedirect(redirect_stop_service))
            std.log.warn("portal: {s} dispatch failed (stale nft redirect until next cycle)", .{redirect_stop_service});
        if (!self.runApStop()) self.setLastError("ap-stop-failed");
        self.active = false;
    }

    // provision.Effects adapters (ctx == *ApController wiring).
    pub fn effectEnterAp(ctx: ?*anyopaque) void {
        const self: *ApController = @ptrCast(@alignCast(ctx.?));
        self.enterAp();
    }

    pub fn effectLeaveAp(ctx: ?*anyopaque) void {
        const self: *ApController = @ptrCast(@alignCast(ctx.?));
        self.leaveAp();
    }

    /// provision.Manager.ap_is_active adapter: the machine's optimistic
    /// ap_active re-syncs against this after every step, so a failed
    /// enterAp is retried on the next observe instead of wedging.
    pub fn effectApActive(ctx: ?*anyopaque) bool {
        const self: *ApController = @ptrCast(@alignCast(ctx.?));
        return self.active;
    }

    fn runApStart(self: *ApController, ssid: []const u8, psk: []const u8) bool {
        if (self.hooks.apStart) |f| return f(self.hooks.ctx, ssid, psk);
        const w = wifi.global orelse {
            std.log.warn("portal: enterAp with no wifi backend", .{});
            return false;
        };
        wifi.apStart(w, ssid, psk) catch |err| {
            std.log.warn("portal: wifi.apStart failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    fn runApStop(self: *ApController) bool {
        if (self.hooks.apStop) |f| return f(self.hooks.ctx);
        const w = wifi.global orelse return true; // nothing to stop
        wifi.apStop(w) catch |err| {
            std.log.warn("portal: wifi.apStop failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    fn runRedirect(self: *ApController, service: []const u8) bool {
        // dinit keeps a scripted oneshot STARTED after a successful run,
        // so a second start is a no-op (service-file note in
        // etc/dinit.d/astro-portal-redirect-start): repeat AP cycles
        // must stop-then-start. Gated on the dinit.zig stop addition
        // (followup) — the FIRST cycle works without it.
        if (self.hooks.dinitStart == null) {
            if (comptime @hasDecl(dinit, "stopServiceByName")) {
                dinit.stopServiceByName(self.dinit_socket, service) catch {};
            }
        }
        return self.runDinit(service);
    }

    fn runDinit(self: *ApController, service: []const u8) bool {
        if (self.hooks.dinitStart) |f| return f(self.hooks.ctx, service);
        dinit.startServiceByName(self.dinit_socket, service) catch |err| {
            std.log.warn("portal: dinit start {s} failed: {s}", .{ service, @errorName(err) });
            return false;
        };
        return true;
    }

    fn dnsUp(self: *ApController) void {
        if (self.dns != null) return;
        const d = DnsCatchAll.init(self.allocator, ap_addr, ap_addr) catch {
            std.log.warn("portal: DNS catch-all alloc failed (auto-open degraded)", .{});
            return;
        };
        d.start() catch |err| {
            std.log.warn("portal: DNS catch-all bind failed: {s} (auto-open degraded)", .{@errorName(err)});
            d.deinit();
            return;
        };
        self.dns = d;
    }

    fn dnsDown(self: *ApController) void {
        const d = self.dns orelse return;
        d.deinit(); // stops first
        self.dns = null;
    }
};

/// Module global set by main once the controller is constructed
/// (update.zig discipline): GET /system reads lastErrorText through it
/// on every surface (system.zig last_error field).
pub var global: ?*ApController = null;

/// system.last_error_source adapter (main wires it at startup).
pub fn lastErrorSource() ?[]const u8 {
    const ctl = global orelse return null;
    return ctl.lastErrorText();
}

// ---- tests -----------------------------------------------------------------

test "portal page is embedded, self-contained, and speaks only the AP subset" {
    try std.testing.expect(page.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, page, "<html") != null);
    // Self-contained: no external fetch targets (docs/06 §2).
    try std.testing.expect(std.mem.indexOf(u8, page, "src=\"http") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"http") == null);
    // The page exercises exactly the unauthenticated subset endpoints.
    try std.testing.expect(std.mem.indexOf(u8, page, "/api/v1/network/wifi/scan") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/api/v1/network/wifi/networks") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/api/v1/network/wifi/connection") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/api/v1/system") != null);
    // Expectation-setting for the single-radio flip (docs/07 §4 item 5).
    try std.testing.expect(std.mem.indexOf(u8, page, "network will drop") != null);
    // Scan results render signal bars (the fill's UI contract).
    try std.testing.expect(std.mem.indexOf(u8, page, "sigbars") != null);
}

test "probe redirect answers 302 with Location: /" {
    var ctx: router.Context = undefined; // handler ignores the context
    const resp = try probeRedirect(&ctx);
    try std.testing.expectEqual(@as(u16, 302), resp.status);
    try std.testing.expectEqualStrings("/", resp.location.?);
}

test "portal page handler serves HTML" {
    var ctx: router.Context = undefined;
    const resp = try getPortalPage(&ctx);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.startsWith(u8, resp.content_type, "text/html"));
    try std.testing.expectEqual(page.len, resp.body.len);
}

test "router.portal_routes carries exactly the page + every probe path" {
    // The routing table lives in router.zig (surface dispatch); this pins
    // the portal side of the contract: GET / serves the page, every
    // probe_paths entry redirects, nothing else and nothing under /api/.
    try std.testing.expectEqual(probe_paths.len + 1, router.portal_routes.len);
    for (router.portal_routes) |r| {
        try std.testing.expect(r.method == .GET);
        try std.testing.expect(!std.mem.startsWith(u8, r.path, "/api/"));
        if (std.mem.eql(u8, r.path, "/")) {
            try std.testing.expectEqual(&getPortalPage, r.handler);
            continue;
        }
        var found = false;
        for (probe_paths) |p| {
            if (std.mem.eql(u8, p, r.path)) found = true;
        }
        try std.testing.expect(found);
        try std.testing.expectEqual(&probeRedirect, r.handler);
    }
}

test "DNS codec: A query gets the AP address, exact pointer-free bytes" {
    const a = std.testing.allocator;
    // "astro.example" A/IN, id 0xBEEF, RD set.
    const query = "\xBE\xEF\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x05astro\x07example\x00" ++
        "\x00\x01\x00\x01";
    const answer = try buildDnsAnswer(a, query, ap_addr);
    defer a.free(answer);
    const expected = "\xBE\xEF\x85\x80\x00\x01\x00\x01\x00\x00\x00\x00" ++ // QR|AA|RD|RA, 1 an
        "\x05astro\x07example\x00\x00\x01\x00\x01" ++ // question echoed
        "\x05astro\x07example\x00" ++ // answer name, VERBATIM (no 0xC0 pointer)
        "\x00\x01\x00\x01" ++ // TYPE A, CLASS IN
        "\x00\x00\x00\x0A" ++ // TTL 10
        "\x00\x04\xC0\xA8\xDF\x01"; // RDLENGTH 4, 192.168.223.1
    try std.testing.expectEqualSlices(u8, expected, answer);
    // Belt and braces: no compression-pointer bytes (>= 0xC0) anywhere
    // between the header and the rdata (0xC0 legitimately appears inside
    // the A rdata itself — 192 == 0xC0 — so stop before it).
    for (answer[12 .. answer.len - 4]) |b| try std.testing.expect(b < 0xC0);
}

test "DNS codec: every name resolves; AAAA gets empty NOERROR, never NXDOMAIN" {
    const a = std.testing.allocator;
    // AAAA (type 28) for the same name, RD clear.
    const q6 = "\x12\x34\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x03foo\x02io\x00" ++ "\x00\x1C\x00\x01";
    const r6 = try buildDnsAnswer(a, q6, ap_addr);
    defer a.free(r6);
    try std.testing.expectEqual(@as(u16, 0x8480), readU16(r6, 2)); // NOERROR, no RD
    try std.testing.expectEqual(@as(u16, 0), readU16(r6, 6)); // ANCOUNT 0
    try std.testing.expectEqual(@as(u16, 1), readU16(r6, 4)); // question echoed
    // RCODE is the low nibble: 0 (NOERROR), NOT 3 (NXDOMAIN).
    try std.testing.expectEqual(@as(u16, 0), readU16(r6, 2) & 0xF);

    // ANY (255) is answered like A.
    const qany = "\x00\x01\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x01x\x00" ++ "\x00\xFF\x00\x01";
    const rany = try buildDnsAnswer(a, qany, ap_addr);
    defer a.free(rany);
    try std.testing.expectEqual(@as(u16, 1), readU16(rany, 6));
}

test "DNS codec: malformed datagrams are rejected (drop, not crash)" {
    const a = std.testing.allocator;
    // Truncated header / empty.
    try std.testing.expectError(error.Malformed, buildDnsAnswer(a, "", ap_addr));
    try std.testing.expectError(error.Malformed, buildDnsAnswer(a, "\x00\x01", ap_addr));
    // A response (QR=1) must not be re-answered (reflection loop guard).
    const resp = "\x00\x01\x80\x00\x00\x01\x00\x00\x00\x00\x00\x00\x01x\x00\x00\x01\x00\x01";
    try std.testing.expectError(error.Malformed, buildDnsAnswer(a, resp, ap_addr));
    // Non-QUERY opcode (STATUS = 2).
    const status_op = "\x00\x01\x10\x00\x00\x01\x00\x00\x00\x00\x00\x00\x01x\x00\x00\x01\x00\x01";
    try std.testing.expectError(error.Malformed, buildDnsAnswer(a, status_op, ap_addr));
    // QDCOUNT 0.
    const noq = "\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expectError(error.Malformed, buildDnsAnswer(a, noq, ap_addr));
    // Compression pointer in the question name.
    const ptr = "\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\xC0\x0C\x00\x01\x00\x01";
    try std.testing.expectError(error.Malformed, buildDnsAnswer(a, ptr, ap_addr));
    // Label overrunning the datagram.
    const overrun = "\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x3Fxy";
    try std.testing.expectError(error.Malformed, buildDnsAnswer(a, overrun, ap_addr));
    // Name present but qtype/qclass missing.
    const short_tail = "\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x01x\x00\x00\x01";
    try std.testing.expectError(error.Malformed, buildDnsAnswer(a, short_tail, ap_addr));
}

test "DnsCatchAll: live socket loop answers over UDP (loopback, ephemeral port)" {
    const a = std.testing.allocator;
    var d = try DnsCatchAll.init(a, .{ 127, 0, 0, 1 }, ap_addr);
    defer d.deinit();
    d.port = 0; // ephemeral — the real 5354 needs the AP address to exist
    try d.start();
    try std.testing.expect(d.running);
    try std.testing.expect(d.bound_port != 0);

    const cfd = udpSocket() orelse return error.SkipZigTest; // no loopback in sandbox
    defer _ = linux.close(cfd);
    var to: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, d.bound_port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    const query = "\xAB\xCD\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x07example\x03com\x00" ++ "\x00\x01\x00\x01";
    try std.testing.expect(linux.errno(linux.sendto(cfd, query.ptr, query.len, 0, @ptrCast(&to), @sizeOf(posix.sockaddr.in))) == .SUCCESS);

    var pfds = [_]posix.pollfd{.{ .fd = cfd, .events = posix.POLL.IN, .revents = 0 }};
    _ = try posix.poll(&pfds, 2000);
    try std.testing.expect(pfds[0].revents & posix.POLL.IN != 0);
    var buf: [512]u8 = undefined;
    const rc = linux.recvfrom(cfd, &buf, buf.len, 0, null, null);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);
    const reply = buf[0..rc];
    try std.testing.expectEqual(@as(u16, 0xABCD), readU16(reply, 0));
    try std.testing.expectEqual(@as(u16, 1), readU16(reply, 6)); // one A answer
    try std.testing.expectEqualSlices(u8, &ap_addr, reply[reply.len - 4 ..]); // = 192.168.223.1

    d.stop();
    try std.testing.expect(!d.running);
    d.stop(); // idempotent
}

test "ApController: enter/leave ordering through scripted hooks (full portal cycle)" {
    const Script = struct {
        var log: std.ArrayList(u8) = .empty;
        var alloc: std.mem.Allocator = undefined;
        var ap_start_ok = true;
        var last_ssid: [32]u8 = undefined;
        var last_ssid_len: usize = 0;
        var last_psk: [16]u8 = undefined;

        fn apStart(_: ?*anyopaque, ssid: []const u8, psk: []const u8) bool {
            log.append(alloc, 'W') catch unreachable; // Wifi ap up
            @memcpy(last_ssid[0..ssid.len], ssid);
            last_ssid_len = ssid.len;
            @memcpy(last_psk[0..psk.len], psk);
            return ap_start_ok;
        }
        fn apStop(_: ?*anyopaque) bool {
            log.append(alloc, 'w') catch unreachable; // wifi ap down
            return true;
        }
        fn dinitStart(_: ?*anyopaque, service: []const u8) bool {
            log.append(alloc, if (std.mem.eql(u8, service, redirect_start_service)) 'N' else 'n') catch unreachable;
            return true;
        }
        fn listenerUp(_: ?*anyopaque) void {
            log.append(alloc, 'L') catch unreachable;
        }
        fn listenerDown(_: ?*anyopaque) void {
            log.append(alloc, 'l') catch unreachable;
        }
    };
    Script.alloc = std.testing.allocator;
    Script.log = .empty;
    defer Script.log.deinit(Script.alloc);

    var ctl = ApController.init(std.testing.allocator, "e5c1770f8ffb4dc7a276869f9f03a1\n");
    defer ctl.deinit();
    ctl.manage_dns = false; // no real socket under unit test
    ctl.hooks = .{
        .apStart = Script.apStart,
        .apStop = Script.apStop,
        .dinitStart = Script.dinitStart,
        .listenerUp = Script.listenerUp,
        .listenerDown = Script.listenerDown,
    };

    // Enter: wifi AP first, then root nft redirects, then the listener.
    ApController.effectEnterAp(&ctl);
    try std.testing.expect(ctl.active);
    try std.testing.expect(ctl.last_error == null);
    try std.testing.expectEqualStrings("WNL", Script.log.items);
    // The identity handed to the radio is the baked derivation.
    try std.testing.expectEqualStrings("astro-9f03a1", Script.last_ssid[0..Script.last_ssid_len]);
    try std.testing.expectEqualStrings("68790122e723996d", Script.last_psk[0..16]);
    // Idempotent while active.
    ctl.enterAp();
    try std.testing.expectEqualStrings("WNL", Script.log.items);

    // Leave: exact reverse order (listener, redirects, radio).
    ApController.effectLeaveAp(&ctl);
    try std.testing.expect(!ctl.active);
    try std.testing.expectEqualStrings("WNL" ++ "lnw", Script.log.items);

    // Wrong-password loop shape: enter again works after a leave.
    ctl.enterAp();
    try std.testing.expectEqualStrings("WNL" ++ "lnw" ++ "WNL", Script.log.items);

    // A failed AP start leaves the controller inactive with last_error
    // set and touches nothing else (no redirects, no listener).
    ctl.leaveAp();
    Script.ap_start_ok = false;
    const before = Script.log.items.len;
    ctl.enterAp();
    try std.testing.expect(!ctl.active);
    try std.testing.expectEqualStrings("ap-start-failed", ctl.last_error.?);
    // The cross-thread mirror serves the same static string (GET /system).
    try std.testing.expectEqualStrings("ap-start-failed", ctl.lastErrorText().?);
    try std.testing.expectEqual(before + 1, Script.log.items.len); // only 'W'

    // A later successful cycle clears it on both paths.
    Script.ap_start_ok = true;
    ctl.enterAp();
    try std.testing.expect(ctl.last_error == null);
    try std.testing.expect(ctl.lastErrorText() == null);
}
