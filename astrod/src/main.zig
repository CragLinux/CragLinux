//! astrod entry point: multi-call dispatch (astroctl), CLI parsing, the two
//! listener surfaces (unix socket + 127.0.0.1 TCP), and a threaded accept
//! loop feeding the router (one std.Thread per connection, capped at
//! max_connections; over-cap connects get an immediate 503 problem).
//! Shared state contract under threading: auth's token cache locks
//! internally, store.Store is RwLock-guarded, system.collect* allocates
//! per-request, and router Contexts (incl. deferred actions) are
//! per-connection by construction.
//!
//! Two deliberate low-level choices, both driven by Zig 0.16's std churn
//! (Io interface rework gutted std.posix and moved std.net/std.fs behind
//! an `Io` handle):
//!  - HTTP is hand-rolled (request line + headers + Content-Length body,
//!    Connection: close). The API surface is small and fixed; ~100 lines
//!    we control beat tracking std.http.Server. Revisit only if keep-alive
//!    or chunked bodies become necessary.
//!  - Sockets use raw std.os.linux syscalls behind tiny wrappers below.
//!    astrod is Linux-only by definition, and the wrappers are the single
//!    place to swap in std.Io.net if a fill agent adopts the Io interface.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const router = @import("router.zig");
const dinit = @import("dinit.zig");
const problem = @import("problem.zig");
const store = @import("store.zig");
const auth = @import("auth.zig");
const astroctl = @import("astroctl.zig");
const system = @import("system.zig");
const update = @import("update.zig");
const events_mod = @import("events.zig");
const ops = @import("ops.zig");
const bus_mod = @import("bus.zig");
const netconf = @import("netconf.zig");
const wifi_mod = @import("wifi.zig");

// Deviations from docs/06 (recorded in MIGRATION-NOTES): socket moved under
// /run/astro/ so the tmpfiles.d-created parent can be astrod:astro-api, and
// the localhost port is 8080 because an unprivileged daemon cannot bind 80.
pub const Options = struct {
    socket_path: []const u8 = "/run/astro/astrod.sock",
    listen: []const u8 = "127.0.0.1:8080",
    store_path: []const u8 = store.default_path,
    token_path: []const u8 = auth.default_token_path,
    /// dinit readiness: one newline byte on this fd once both listeners
    /// are bound (dinit ready-notification = pipefd:N).
    ready_fd: ?posix.fd_t = null,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| try args.append(arena, arg);

    // Multi-call: argv[0] basename "astroctl", or "astrod ctl ...".
    const base = std.fs.path.basename(args.items[0]);
    if (std.mem.eql(u8, base, "astroctl"))
        return astroctl.run(gpa, args.items[1..]);
    if (args.items.len > 1 and std.mem.eql(u8, args.items[1], "ctl"))
        return astroctl.run(gpa, args.items[2..]);

    const opts = parseArgs(args.items[1..]) catch |err| {
        std.debug.print("astrod: bad arguments ({t})\nusage: astrod [--socket=PATH] [--listen=ADDR:PORT] [--store=PATH] [--token=PATH] [--ready-fd=N]\n", .{err});
        return 2;
    };

    // Connection threads allocate through init.gpa concurrently — it is
    // documented threadsafe in Zig 0.16 (std.process.Init.gpa).
    // SchemaTooNew is the only load failure (missing/corrupt files degrade
    // to defaults inside load): refusing to run beats silently rewriting —
    // and truncating — a document a newer daemon wrote.
    var st = store.Store.load(gpa, opts.store_path) catch |err| switch (err) {
        store.LoadError.SchemaTooNew => {
            std.debug.print("astrod: {s} has a newer schema than this daemon understands; refusing to start\n", .{opts.store_path});
            return 1;
        },
    };
    defer st.deinit();

    try serve(gpa, opts, &st);
    return 0;
}

pub fn parseArgs(args: []const []const u8) !Options {
    var opts: Options = .{};
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--socket=")) {
            opts.socket_path = arg["--socket=".len..];
        } else if (std.mem.startsWith(u8, arg, "--listen=")) {
            opts.listen = arg["--listen=".len..];
        } else if (std.mem.startsWith(u8, arg, "--store=")) {
            opts.store_path = arg["--store=".len..];
        } else if (std.mem.startsWith(u8, arg, "--token=")) {
            opts.token_path = arg["--token=".len..];
        } else if (std.mem.startsWith(u8, arg, "--ready-fd=")) {
            opts.ready_fd = try std.fmt.parseInt(posix.fd_t, arg["--ready-fd=".len..], 10);
        } else {
            return error.UnknownArgument;
        }
    }
    return opts;
}

const Surface = enum { unix, tcp };

/// Connection-thread cap (docs/06 §7 backpressure family). Strictly above
/// the SSE subscriber budget (events.max_subscribers = 16) so a full set
/// of long-lived streams can never starve interactive requests, yet small
/// enough to bound RSS on the 16 MiB budget (idle connection threads cost
/// pages actually touched, not stack reservations).
pub const max_connections = 32;

/// Precomputed over-cap response: the accept loop must not allocate or
/// touch shared state to reject work when saturated.
const overloaded_body =
    \\{"type":"urn:astro:problem:overloaded","title":"Service Unavailable","status":503,"detail":"connection limit reached, retry shortly"}
;
const overloaded_response = std.fmt.comptimePrint(
    "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/problem+json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
    .{ overloaded_body.len, overloaded_body },
);

const Server = struct {
    /// Thread-safe: every connection thread allocates through this.
    gpa: std.mem.Allocator,
    token_path: []const u8,
    st: *store.Store,
    events: *events_mod.EventBus,
    active: std.atomic.Value(u32) = .init(0),
};

fn serve(gpa: std.mem.Allocator, opts: Options, st: *store.Store) !void {
    // Stage-2 subsystems. The operations registry and event ring always
    // exist; the update manager only when the system bus answers — the
    // /update endpoints degrade to 503 rauc-unavailable without it
    // (docs/06 §7), so a missing dbus-daemon never blocks the API itself.
    var registry = ops.Registry.init(gpa);
    defer registry.deinit();
    ops.global = &registry;
    defer ops.global = null;
    var event_bus = events_mod.EventBus.init(gpa);
    defer event_bus.deinit();

    var bus_owned: ?*bus_mod.Bus = null;
    defer if (bus_owned) |b| b.deinit();
    var mgr_owned: ?*update.Manager = null;
    defer if (mgr_owned) |m| {
        update.manager = null;
        m.deinit();
    };
    if (bus_mod.connectSystemRetry(gpa, 5)) |b| {
        bus_owned = b;
        if (b.start()) {
            // Manager.init installs the RAUC signal watches and runs the
            // restart re-attach probe. The AD-021 gate compares against
            // the running release (copied by init; the arena is
            // startup-only).
            var startup_arena = std.heap.ArenaAllocator.init(gpa);
            defer startup_arena.deinit();
            const info = try system.collect(startup_arena.allocator());
            const m = try update.Manager.init(gpa, b, &registry, &event_bus, info.release);
            mgr_owned = m;
            update.manager = m;
        } else |err| {
            std.log.warn("astrod: bus thread start failed ({t}); update endpoints answer 503", .{err});
        }
    } else |err| {
        std.log.warn("astrod: system D-Bus unavailable ({t}); update endpoints answer 503", .{err});
    }

    // Phase-3 network subsystem (docs/07 §2). netconf renders
    // dhcpcd.conf + resolv.conf from the store, rebinds dhcpcd, and
    // watches the lease-export dir; the wifi backend mirrors iwd's
    // object tree over the spine. Both deinit before main's
    // store.deinit (defers run before serve returns) — the store may
    // reference wifi-owned connection strings.
    var netconf_owned: ?*netconf.Manager = null;
    defer if (netconf_owned) |m| {
        netconf.global = null;
        m.deinit();
    };
    {
        const m = try netconf.Manager.init(gpa, st, &event_bus);
        netconf_owned = m;
        netconf.global = m;
        m.start();
    }

    var wifi_owned: ?*wifi_mod.Wifi = null;
    defer if (wifi_owned) |w| {
        wifi_mod.global = null;
        w.deinit();
    };
    if (bus_owned) |b| {
        if (wifi_mod.Wifi.init(gpa, b, st, &registry, &event_bus)) |w| {
            wifi_owned = w;
            wifi_mod.global = w;
        } else |err| {
            std.log.warn("astrod: wifi backend unavailable ({t}); wifi endpoints degrade", .{err});
        }
    }

    const unix_fd = try listenUnix(opts.socket_path);
    defer _ = linux.close(unix_fd);
    const tcp_fd = try listenTcp(opts.listen);
    defer _ = linux.close(tcp_fd);

    if (opts.ready_fd) |fd| try writeAllFd(fd, "\n");

    var server: Server = .{ .gpa = gpa, .token_path = opts.token_path, .st = st, .events = &event_bus };

    var pollfds = [_]posix.pollfd{
        .{ .fd = unix_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = tcp_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        // posix.poll retries EINTR internally.
        _ = try posix.poll(&pollfds, -1);
        for (&pollfds) |*pfd| {
            if (pfd.revents & posix.POLL.IN == 0) continue;
            const conn: posix.fd_t = @intCast(sys(linux.accept4(pfd.fd, null, null, posix.SOCK.CLOEXEC)) catch continue);
            const surface: Surface = if (pfd.fd == unix_fd) .unix else .tcp;

            // Claim a slot before spawning; over cap → immediate 503 and
            // close, without allocating (see overloaded_response).
            if (server.active.fetchAdd(1, .acq_rel) >= max_connections) {
                _ = server.active.fetchSub(1, .acq_rel);
                writeAllFd(conn, overloaded_response) catch {};
                _ = linux.close(conn);
                continue;
            }
            const t = std.Thread.spawn(.{}, connectionThread, .{ &server, conn, surface }) catch {
                _ = server.active.fetchSub(1, .acq_rel);
                _ = linux.close(conn);
                continue;
            };
            t.detach();
        }
    }
}

fn connectionThread(server: *Server, conn: posix.fd_t, surface: Surface) void {
    defer _ = server.active.fetchSub(1, .acq_rel);
    defer _ = linux.close(conn);
    // A failed request must not take the daemon down.
    handleConnection(server, conn, surface) catch {};
}

/// Map a raw syscall return to error.Unexpected (which logs the errno in
/// debug builds). Fine-grained error taxonomy is not skeleton work.
fn sys(rc: usize) posix.UnexpectedError!usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) return posix.unexpectedErrno(e);
    return rc;
}

fn listenUnix(path: []const u8) !posix.fd_t {
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);

    // Stale socket file from a previous run would make bind fail; removing
    // it is safe because dinit guarantees a single astrod instance.
    const path_z = try posix.toPosixPath(path);
    _ = linux.unlink(&path_z);

    const fd: posix.fd_t = @intCast(try sys(linux.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(fd);
    _ = try sys(linux.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)));
    _ = try sys(linux.listen(fd, 16));
    return fd;
}

fn listenTcp(spec: []const u8) !posix.fd_t {
    const parsed = try parseHostPort(spec);
    var addr: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, parsed.port),
        .addr = @bitCast(parsed.octets),
    };
    const fd: posix.fd_t = @intCast(try sys(linux.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(fd);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    _ = try sys(linux.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)));
    _ = try sys(linux.listen(fd, 16));
    return fd;
}

const HostPort = struct { octets: [4]u8, port: u16 };

// IPv4 only: the listener is 127.0.0.1 by policy (AD-014/AD-025); LAN and
// IPv6 exposure arrive with the opt-in LAN surface, not before.
pub fn parseHostPort(spec: []const u8) !HostPort {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return error.InvalidAddress;
    const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch return error.InvalidAddress;
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, spec[0..colon], '.');
    for (&octets) |*o| {
        const part = it.next() orelse return error.InvalidAddress;
        o.* = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }
    if (it.next() != null) return error.InvalidAddress;
    return .{ .octets = octets, .port = port };
}

// ---- HTTP/1.1, minimal -----------------------------------------------------

const max_head_len = 16 * 1024;
const max_body_len = 64 * 1024;

pub const ParsedRequest = struct {
    method: []const u8,
    /// Request-target with any query string split off (exact-match router).
    path: []const u8,
    /// Query string without the '?' ("" when absent); handlers with
    /// documented parameters parse it (update.queryFlag).
    query: []const u8 = "",
    authorization: ?[]const u8 = null,
    content_length: usize = 0,
    content_type: ?[]const u8 = null,
    /// SSE resume header for GET /api/v1/events.
    last_event_id: ?[]const u8 = null,
    /// Offset of the first body byte within the read buffer.
    body_start: usize = 0,
};

pub const ParseError = error{BadRequest};

/// Parse request line + headers from `buf` (which holds everything read so
/// far, terminator included). Only the headers the daemon consumes are
/// extracted; unknown headers are skipped (robustness principle). The
/// body-length cap is enforced by handleConnection, not here — the one
/// streamed-upload route is exempt from it.
pub fn parseRequest(buf: []const u8) ParseError!ParsedRequest {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.BadRequest;
    var req: ParsedRequest = .{ .method = undefined, .path = undefined, .body_start = head_end + 4 };

    var lines = std.mem.splitSequence(u8, buf[0..head_end], "\r\n");
    const request_line = lines.next() orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    req.method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version = parts.next() orelse return error.BadRequest;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadRequest;
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        req.path = target[0..q];
        req.query = target[q + 1 ..];
    } else {
        req.path = target;
    }
    if (req.path.len == 0) return error.BadRequest;

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "authorization")) {
            req.authorization = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            req.content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            req.content_type = value;
        } else if (std.ascii.eqlIgnoreCase(name, "last-event-id")) {
            req.last_event_id = value;
        }
    }
    return req;
}

/// POST /api/v1/update with an application/octet-stream body is the one
/// request whose body may (and normally does) exceed max_body_len:
/// bundles are streamed straight to the staging directory, never buffered
/// in RAM (docs/06 §7; the 16 MiB RSS budget).
fn isStreamedUpload(method: router.Method, req: ParsedRequest) bool {
    if (method != .POST or !std.mem.eql(u8, req.path, "/api/v1/update")) return false;
    const ct = req.content_type orelse return false;
    return std.ascii.startsWithIgnoreCase(ct, "application/octet-stream");
}

fn handleConnection(server: *Server, fd: posix.fd_t, surface: Surface) !void {
    const st = server.st;
    // Arena per request: handlers allocate freely, everything dies here.
    var arena_state = std.heap.ArenaAllocator.init(server.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [max_head_len]u8 = undefined;
    var len: usize = 0;
    const head_end = while (true) {
        if (len == buf.len) return writeProblem(fd, arena, st, 431, "Request Header Fields Too Large");
        const n = posix.read(fd, buf[len..]) catch return;
        if (n == 0) return; // peer closed before completing a request
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |i| break i + 4;
    };

    const req = parseRequest(buf[0..len]) catch
        return writeProblem(fd, arena, st, 400, "Bad Request");

    const method = router.Method.parse(req.method) orelse
        return writeProblem(fd, arena, st, 405, "Method Not Allowed");

    // AD-014: unix peers passed the astro-api group gate at connect();
    // the TCP surface requires the firstboot bearer token. Fail-closed —
    // no token file yet means no TCP access.
    const authorized = switch (surface) {
        .unix => auth.allowUnixPeer(),
        .tcp => auth.checkBearer(server.token_path, req.authorization),
    };

    var ctx: router.Context = .{ .allocator = arena, .store = st, .event_bus = server.events, .request = .{
        .method = method,
        .path = req.path,
        .query = req.query,
        .authorization = req.authorization,
        .last_event_id = req.last_event_id,
    } };

    if (isStreamedUpload(method, req)) {
        // Auth precedes the sink here — an unauthorized client must not
        // get bytes written to /data. (The 401 goes out before the body
        // is drained; Connection: close makes that acceptable.)
        if (!authorized) return writeResponse(fd, arena, unauthorizedResponse(&ctx));
        const mgr = update.manager orelse return writeResponse(fd, arena, router.problemResponse(&ctx, .{
            .type = "urn:astro:problem:rauc-unavailable",
            .title = "Service Unavailable",
            .status = 503,
            .detail = "update subsystem is not connected to D-Bus",
        }));
        const already = @min(len - head_end, req.content_length);
        var reader: FdReader = .{ .fd = fd };
        const staged = mgr.stageStream(arena, buf[head_end..][0..already], &reader, req.content_length) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InsufficientStorage => return writeResponse(fd, arena, router.problemResponse(&ctx, .{
                .type = "urn:astro:problem:insufficient-storage",
                .title = "Insufficient Storage",
                .status = 507,
                .detail = "not enough free space on /data to stage the bundle",
            })),
            error.StagingFailed => return writeResponse(fd, arena, router.problemResponse(&ctx, .{
                .type = "urn:astro:problem:staging-failed",
                .title = "Internal Server Error",
                .status = 500,
                .detail = "could not write the bundle to the staging directory",
            })),
        };
        ctx.request.staged_upload = staged;
    } else {
        if (req.content_length > max_body_len)
            return writeProblem(fd, arena, st, 413, "Content Too Large");
        // Drain the body fully before answering (also for the 401 path:
        // closing with unread data can RST the response away).
        const body = try arena.alloc(u8, req.content_length);
        const already = @min(len - head_end, body.len);
        @memcpy(body[0..already], buf[head_end..][0..already]);
        var got = already;
        while (got < body.len) {
            const n = posix.read(fd, body[got..]) catch return;
            if (n == 0) return;
            got += n;
        }
        ctx.request.body = body;
        if (!authorized) return writeResponse(fd, arena, unauthorizedResponse(&ctx));
    }

    const resp = router.dispatch(&ctx);

    // SSE mode (GET /api/v1/events): the subscription streams frames on
    // this thread until the client goes away; no Content-Length, no
    // deferred actions (the handler sets none on this path).
    if (ctx.sse) |sub| {
        defer sub.cancel();
        writeAllFd(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n") catch return;
        var w: FdWriter = .{ .fd = fd };
        events_mod.serveStream(sub, &w);
        return;
    }

    try writeResponse(fd, arena, resp);

    // Deferred actions run with the response already on the wire: a
    // SHUTDOWN makes dinit kill astrod immediately, which raced (and
    // truncated) the 202 when issued from inside the handler.
    if (ctx.deferred) |action| switch (action) {
        .shutdown => |t| dinit.requestShutdown(dinit.default_socket_path, t) catch {},
    };
}

fn unauthorizedResponse(ctx: *router.Context) router.Response {
    return router.problemResponse(ctx, .{
        .type = "urn:astro:problem:unauthorized",
        .title = "Unauthorized",
        .status = 401,
    });
}

/// Socket-backed reader for the streamed-upload sink (fsutil shape).
const FdReader = struct {
    fd: posix.fd_t,
    pub fn read(self: *const FdReader, buffer: []u8) !usize {
        return posix.read(self.fd, buffer);
    }
};

/// Socket-backed writer for the SSE stream (events.serveStream shape).
const FdWriter = struct {
    fd: posix.fd_t,
    pub fn writeAll(self: *const FdWriter, bytes: []const u8) !void {
        try writeAllFd(self.fd, bytes);
    }
};

fn writeProblem(fd: posix.fd_t, arena: std.mem.Allocator, st: *store.Store, status: u16, title: []const u8) !void {
    var ctx: router.Context = .{ .allocator = arena, .store = st, .request = .{ .method = .GET, .path = "/" } };
    try writeResponse(fd, arena, router.problemResponse(&ctx, .{
        .type = "urn:astro:problem:bad-request",
        .title = title,
        .status = status,
    }));
}

fn writeResponse(fd: posix.fd_t, arena: std.mem.Allocator, resp: router.Response) !void {
    const head = try std.fmt.allocPrint(arena, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ resp.status, statusText(resp.status), resp.content_type, resp.body.len });
    try writeAllFd(fd, head);
    try writeAllFd(fd, resp.body);
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        off += try sys(linux.write(fd, bytes[off..].ptr, bytes.len - off));
    }
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Content Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        507 => "Insufficient Storage",
        else => "Status",
    };
}

// Pull in every module so `zig build test` runs the whole tree.
test {
    _ = router;
    _ = problem;
    _ = store;
    _ = auth;
    _ = astroctl;
    _ = system;
    _ = update;
    _ = events_mod;
    _ = ops;
    _ = bus_mod;
    _ = @import("dinit.zig");
    _ = @import("fsutil.zig");
    _ = @import("sync.zig");
    _ = @import("rauc.zig");
    _ = @import("version.zig");
    _ = @import("link.zig");
    _ = @import("netconf.zig");
    _ = @import("wifi.zig");
    _ = @import("conformance_test.zig");
}

test "parseArgs handles all flags and rejects unknowns" {
    const opts = try parseArgs(&.{
        "--socket=/tmp/t.sock",
        "--listen=127.0.0.1:8899",
        "--store=/tmp/astro.json",
        "--ready-fd=3",
    });
    try std.testing.expectEqualStrings("/tmp/t.sock", opts.socket_path);
    try std.testing.expectEqualStrings("127.0.0.1:8899", opts.listen);
    try std.testing.expectEqualStrings("/tmp/astro.json", opts.store_path);
    try std.testing.expectEqual(@as(posix.fd_t, 3), opts.ready_fd.?);

    const defaults = try parseArgs(&.{});
    try std.testing.expectEqualStrings("/run/astro/astrod.sock", defaults.socket_path);
    try std.testing.expectEqual(@as(?posix.fd_t, null), defaults.ready_fd);

    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{"--bogus"}));
}

test "parseHostPort" {
    const hp = try parseHostPort("127.0.0.1:8080");
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, hp.octets);
    try std.testing.expectEqual(@as(u16, 8080), hp.port);
    try std.testing.expectError(error.InvalidAddress, parseHostPort("localhost"));
    try std.testing.expectError(error.InvalidAddress, parseHostPort("1.2.3:80"));
}

test "parseRequest extracts method, path, query, auth, and content-length" {
    const raw = "POST /api/v1/system/reboot?delay=1 HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer tok\r\nContent-Length: 2\r\n\r\n{}";
    const req = try parseRequest(raw);
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/api/v1/system/reboot", req.path);
    try std.testing.expectEqualStrings("delay=1", req.query);
    try std.testing.expectEqualStrings("Bearer tok", req.authorization.?);
    try std.testing.expectEqual(@as(usize, 2), req.content_length);
    try std.testing.expectEqualStrings("{}", raw[req.body_start..]);
    try std.testing.expect(req.content_type == null);
    try std.testing.expect(req.last_event_id == null);
}

test "parseRequest extracts content-type and last-event-id; upload divert predicate" {
    const raw = "POST /api/v1/update?force=true HTTP/1.1\r\nContent-Type: application/octet-stream\r\nContent-Length: 999999999\r\n\r\n";
    const req = try parseRequest(raw);
    try std.testing.expectEqualStrings("application/octet-stream", req.content_type.?);
    try std.testing.expectEqualStrings("force=true", req.query);
    try std.testing.expect(isStreamedUpload(.POST, req));
    // Same path with a JSON content type stays on the buffered body path.
    const json_req = try parseRequest("POST /api/v1/update HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    try std.testing.expect(!isStreamedUpload(.POST, json_req));

    const sse = try parseRequest("GET /api/v1/events HTTP/1.1\r\nLast-Event-ID: 42\r\n\r\n");
    try std.testing.expectEqualStrings("42", sse.last_event_id.?);
    try std.testing.expect(!isStreamedUpload(.GET, sse));
}

test "parseRequest rejects garbage" {
    try std.testing.expectError(error.BadRequest, parseRequest("not http\r\n\r\n"));
}
