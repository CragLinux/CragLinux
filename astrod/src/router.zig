//! Route table + dispatch. The table is a comptime slice so CI can verify
//! handlers and openapi.yaml never diverge (AD-013 "spec-driven route
//! table") — see the conformance test at the bottom.

const std = @import("std");
const problem = @import("problem.zig");
const system = @import("system.zig");
const dinit = @import("dinit.zig");
const store_mod = @import("store.zig");
const update = @import("update.zig");
const events = @import("events.zig");
const ops = @import("ops.zig");
const netconf = @import("netconf.zig");

/// Only the verbs the API uses (docs/06 §4); parse returns null for others
/// so dispatch can answer 405 rather than crash on e.g. CONNECT.
pub const Method = enum {
    GET,
    PUT,
    PATCH,
    POST,
    DELETE,

    pub fn parse(s: []const u8) ?Method {
        return std.meta.stringToEnum(Method, s);
    }
};

pub const Request = struct {
    method: Method,
    /// Path only — the query string is split off by the HTTP layer.
    path: []const u8,
    /// Raw query string without the '?' ("" when absent). Parsed by the
    /// few handlers that document parameters (update.queryFlag).
    query: []const u8 = "",
    authorization: ?[]const u8 = null,
    /// SSE resume header (Last-Event-ID), threaded through for /events.
    last_event_id: ?[]const u8 = null,
    body: []const u8 = "",
    /// Set instead of `body` when the HTTP layer diverted a large
    /// application/octet-stream upload straight to the staging directory
    /// (POST /api/v1/update only): the staged bundle path.
    staged_upload: ?[:0]const u8 = null,
};

pub const Response = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    /// Either static or allocated from ctx.allocator (an arena per request
    /// in main.zig, so ownership never needs tracking here).
    body: []const u8,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    request: Request,
    store: *store_mod.Store,
    /// Bound value of a trailing {param} route segment (e.g. the "op-3"
    /// of GET /api/v1/operations/op-3); set by dispatch, slices into
    /// request.path. Null on exact-match routes.
    param: ?[]const u8 = null,
    /// Action the connection layer must run AFTER the response is on the
    /// wire. Power actions cannot run inline: dinit begins teardown (and
    /// kills astrod) immediately, so an inline SHUTDOWN raced the 202 and
    /// clients saw a truncated response (observed on qemu-armv7).
    /// Per-connection by construction: each connection thread builds its
    /// own Context, so deferred actions never cross threads.
    deferred: ?DeferredAction = null,
    /// The daemon's event bus (null under router unit tests, which
    /// construct no bus — GET /events answers 501 then).
    event_bus: ?*events.EventBus = null,
    /// Set by getEvents when the connection turns into an SSE stream: the
    /// connection layer skips writeResponse and serves frames until the
    /// client goes away, then cancels the subscription. Per-connection,
    /// same discipline as `deferred`.
    sse: ?*events.Subscription = null,
};

pub const DeferredAction = union(enum) {
    shutdown: dinit.ShutdownType,
};

pub const Handler = *const fn (ctx: *Context) anyerror!Response;

pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: Handler,
};

/// Exported for the conformance test and future spec-driven codegen.
/// Paths may end in exactly one "{param}" segment (OpenAPI syntax; the
/// conformance test matches it verbatim against the spec's path key).
pub const routes: []const Route = &.{
    .{ .method = .GET, .path = "/api/v1/system", .handler = getSystem },
    .{ .method = .POST, .path = "/api/v1/system/reboot", .handler = postReboot },
    .{ .method = .POST, .path = "/api/v1/system/poweroff", .handler = postPoweroff },
    .{ .method = .GET, .path = "/api/v1/openapi.json", .handler = getOpenapi },
    // Stage-2 surface (docs/06 §5.3, §4): update group handlers live in
    // update.zig; events/operations glue is below. When the backing
    // subsystem is absent the update handlers answer 503
    // rauc-unavailable and the events/operations handlers 501 (only unit
    // tests run without a registry/event bus).
    .{ .method = .GET, .path = "/api/v1/update/status", .handler = update.getUpdateStatus },
    .{ .method = .POST, .path = "/api/v1/update", .handler = update.postUpdate },
    .{ .method = .POST, .path = "/api/v1/update/apply", .handler = update.postUpdateApply },
    .{ .method = .POST, .path = "/api/v1/update/rollback", .handler = update.postUpdateRollback },
    .{ .method = .GET, .path = "/api/v1/events", .handler = getEvents },
    .{ .method = .GET, .path = "/api/v1/operations", .handler = getOperations },
    .{ .method = .GET, .path = "/api/v1/operations/{id}", .handler = getOperation },
    // Phase-3 network group (docs/06 §5.2): handlers live in netconf.zig
    // (wifi mechanism in wifi.zig). Without the wired backends
    // (netconf.global / wifi.global null — unit builds) every route
    // answers 501 not-implemented, keeping the group test meaningful.
    // cellular is 501 by CONTRACT (reserved namespace), not by
    // implementation state. /network/wifi/ap deliberately absent: AP
    // mode is phase 4.
    .{ .method = .GET, .path = "/api/v1/network", .handler = netconf.getNetwork },
    .{ .method = .GET, .path = "/api/v1/network/ethernet/{iface}", .handler = netconf.getEthernetIface },
    .{ .method = .PUT, .path = "/api/v1/network/ethernet/{iface}", .handler = netconf.putEthernetIface },
    .{ .method = .PATCH, .path = "/api/v1/network/ethernet/{iface}", .handler = netconf.patchEthernetIface },
    .{ .method = .GET, .path = "/api/v1/network/wifi", .handler = netconf.getWifi },
    .{ .method = .POST, .path = "/api/v1/network/wifi/scan", .handler = netconf.postWifiScan },
    .{ .method = .GET, .path = "/api/v1/network/wifi/networks", .handler = netconf.getWifiNetworks },
    .{ .method = .GET, .path = "/api/v1/network/wifi/connection", .handler = netconf.getWifiConnection },
    .{ .method = .PUT, .path = "/api/v1/network/wifi/connection", .handler = netconf.putWifiConnection },
    .{ .method = .DELETE, .path = "/api/v1/network/wifi/connection", .handler = netconf.deleteWifiConnection },
    .{ .method = .GET, .path = "/api/v1/network/wan", .handler = netconf.getWan },
    .{ .method = .PUT, .path = "/api/v1/network/wan", .handler = netconf.putWan },
    .{ .method = .GET, .path = "/api/v1/network/cellular", .handler = cellularReserved },
    .{ .method = .PUT, .path = "/api/v1/network/cellular", .handler = cellularReserved },
};

/// Match a route path against a request path. Exact match, or — when the
/// route ends in a "{param}" segment — prefix match binding the request's
/// final segment (which must be non-empty and contain no further '/').
/// Returns the bound param (null for exact routes), or null wrapped in
/// no-match. Deliberately minimal: one trailing parameter only.
fn matchPath(route_path: []const u8, req_path: []const u8) ?(?[]const u8) {
    if (std.mem.endsWith(u8, route_path, "}")) {
        const brace = std.mem.lastIndexOfScalar(u8, route_path, '{') orelse return null;
        const prefix = route_path[0..brace]; // includes the trailing '/'
        if (!std.mem.startsWith(u8, req_path, prefix)) return null;
        const rest = req_path[prefix.len..];
        if (rest.len == 0) return null;
        if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
        return rest;
    }
    if (std.mem.eql(u8, route_path, req_path)) return @as(?[]const u8, null);
    return null;
}

/// Never returns an error: handler failures become 500 problem+json so the
/// connection layer always has something well-formed to write.
pub fn dispatch(ctx: *Context) Response {
    var path_known = false;
    for (routes) |route| {
        if (matchPath(route.path, ctx.request.path)) |param| {
            path_known = true;
            if (route.method == ctx.request.method) {
                ctx.param = param;
                return route.handler(ctx) catch
                    problemResponse(ctx, .{
                        .type = "urn:astro:problem:internal",
                        .title = "Internal Server Error",
                        .status = 500,
                    });
            }
        }
    }
    if (path_known) {
        return problemResponse(ctx, .{
            .type = "urn:astro:problem:method-not-allowed",
            .title = "Method Not Allowed",
            .status = 405,
        });
    }
    return problemResponse(ctx, .{
        .type = "urn:astro:problem:not-found",
        .title = "Not Found",
        .status = 404,
    });
}

/// Build a problem+json Response; also used by main.zig for 401 on the
/// TCP surface and for HTTP parse errors.
pub fn problemResponse(ctx: *Context, p: problem.Problem) Response {
    const body = problem.render(ctx.allocator, p) catch
        // OOM while rendering an error: fall back to a static body that is
        // still valid problem+json, keeping the wire contract.
        \\{"type":"urn:astro:problem:internal","title":"Internal Server Error","status":500}
    ;
    return .{ .status = p.status, .content_type = problem.content_type, .body = body };
}

// ---- v1 handlers -----------------------------------------------------------

fn getSystem(ctx: *Context) anyerror!Response {
    // Per-request arena allocation (thread-safe by construction; the old
    // module-static buffers raced once the server went threaded).
    const info = try system.collectWith(ctx.allocator, ctx.store.getProvisioning());
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, info, .{}) };
}

fn postReboot(ctx: *Context) anyerror!Response {
    return powerAction(ctx, .reboot);
}

fn postPoweroff(ctx: *Context) anyerror!Response {
    return powerAction(ctx, .poweroff);
}

// Reboot/poweroff stay root-only (docs/02 §7); astrod asks dinit over its
// control socket. On a dinit-chimera image there are no sys-reboot/
// sys-poweroff oneshots — /usr/bin/reboot IS dinit's shutdown client — so
// the correct mechanism is the SHUTDOWN command (verified in dinit.zig).
//
// The handler only PROBES dinit (connect + version handshake) so failures
// still surface as HTTP errors; the SHUTDOWN itself is deferred to the
// connection layer (see Context.deferred). The probe-to-action window is a
// benign TOCTOU: losing dinit in between means the box is going down anyway.
fn powerAction(ctx: *Context, t: dinit.ShutdownType) anyerror!Response {
    var probe = dinit.Client.connect(dinit.default_socket_path) catch |err| return problemResponse(ctx, switch (err) {
        // Unreachable/permission-denied control socket: the daemon itself
        // is fine, the mechanism is unavailable — 503, not 500.
        error.ConnectFailed => .{
            .type = "urn:astro:problem:dinit-unavailable",
            .title = "Service Unavailable",
            .status = 503,
            .detail = "cannot reach the dinit control socket",
        },
        else => .{
            .type = "urn:astro:problem:internal",
            .title = "Internal Server Error",
            .status = 500,
            .detail = "dinit control handshake failed",
        },
    });
    probe.deinit();
    ctx.deferred = .{ .shutdown = t };
    return .{ .status = 202, .body = "{\"operation\":null}" };
}

fn getOpenapi(_: *Context) anyerror!Response {
    return .{ .status = 200, .body = openapi_json };
}

/// 501 per docs/06 §5 practice for endpoints whose backing subsystem is
/// not wired in the running build (in practice: unit tests, which
/// construct no registry/event bus).
fn notImplemented(ctx: *Context) anyerror!Response {
    const detail = try std.fmt.allocPrint(
        ctx.allocator,
        "{t} {s}: the backing subsystem is not wired in this build",
        .{ ctx.request.method, ctx.request.path },
    );
    return problemResponse(ctx, .{
        .type = "urn:astro:problem:not-implemented",
        .title = "Not Implemented",
        .status = 501,
        .detail = detail,
    });
}

/// GET,PUT /api/v1/network/cellular — 501 BY CONTRACT (docs/06 §5.2
/// reserved namespace): the problem detail documents the roadmap so
/// clients can distinguish "reserved" from "not wired yet".
fn cellularReserved(ctx: *Context) anyerror!Response {
    return problemResponse(ctx, .{
        .type = "urn:astro:problem:not-implemented",
        .title = "Not Implemented",
        .status = 501,
        .detail = "cellular is a reserved namespace (docs/06 §5.2): planned as ModemManager beside iwd with astrod orchestrating (docs/07 §1); the endpoint shape is pinned by the OpenAPI contract and will activate in a future release",
    });
}

/// GET /api/v1/events — subscribe and flip the connection into SSE mode:
/// the returned Response is a placeholder (the connection layer writes
/// the stream head + frames itself once ctx.sse is set). Replay honors
/// the Last-Event-ID header (docs/06 §7).
fn getEvents(ctx: *Context) anyerror!Response {
    const bus = ctx.event_bus orelse return notImplemented(ctx);
    const sub = bus.subscribe(events.parseLastEventId(ctx.request.last_event_id)) catch |err| switch (err) {
        error.TooManySubscribers => return problemResponse(ctx, .{
            .type = "urn:astro:problem:overloaded",
            .title = "Service Unavailable",
            .status = 503,
            .detail = "SSE subscriber limit (16) reached; retry after another consumer disconnects",
        }),
        error.OutOfMemory => return error.OutOfMemory,
    };
    ctx.sse = sub;
    return .{ .status = 200, .content_type = events.sse_content_type, .body = "" };
}

/// GET /api/v1/operations — every operation this daemon run knows,
/// newest first (docs/06 §4; the registry is volatile by contract).
fn getOperations(ctx: *Context) anyerror!Response {
    const reg = ops.global orelse return notImplemented(ctx);
    const list = try reg.list(ctx.allocator);
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, list, .{}) };
}

/// GET /api/v1/operations/{id} — one operation; 404 for ids the volatile
/// registry does not hold (including pre-restart ids, docs/06 §7).
fn getOperation(ctx: *Context) anyerror!Response {
    const reg = ops.global orelse return notImplemented(ctx);
    const id = ctx.param.?;
    const op = (try reg.get(ctx.allocator, id)) orelse return problemResponse(ctx, .{
        .type = "urn:astro:problem:not-found",
        .title = "Not Found",
        .status = 404,
        .detail = try std.fmt.allocPrint(ctx.allocator, "no operation {s} in this daemon run (the registry is in-memory and restarts empty)", .{id}),
    });
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, op, .{}) };
}

/// The spec file (JSON-syntax YAML), served byte-for-byte.
pub const openapi_json = @embedFile("openapi_spec");

// ---- tests -----------------------------------------------------------------
// (The AD-013 spec<->route conformance gate lives in conformance_test.zig.)

fn testCtx(allocator: std.mem.Allocator, st: *store_mod.Store, method: Method, path: []const u8) Context {
    return .{ .allocator = allocator, .store = st, .request = .{ .method = method, .path = path } };
}

// Handlers only read the store, so a defaults-only store (missing file)
// stands in for a real one.
fn testStore() !store_mod.Store {
    return store_mod.Store.load(std.testing.allocator, "/nonexistent/astro.json");
}

test "dispatch routes GET /api/v1/system to a 200 JSON body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();
    var ctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/system");
    const resp = dispatch(&ctx);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("board") != null);
    try std.testing.expect(parsed.value.object.get("uptime_s") != null);
    // Provisioning comes from the store (defaults: "factory").
    try std.testing.expectEqualStrings("factory", parsed.value.object.get("provisioning").?.string);
}

test "dispatch answers 404 problem+json for unknown paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();
    var ctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/nope");
    const resp = dispatch(&ctx);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
    try std.testing.expectEqualStrings(problem.content_type, resp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "urn:astro:problem:not-found") != null);
}

test "dispatch answers 405 for known path with wrong method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();
    var ctx = testCtx(arena.allocator(), &st, .DELETE, "/api/v1/system");
    const resp = dispatch(&ctx);
    try std.testing.expectEqual(@as(u16, 405), resp.status);
}

test "matchPath: exact, trailing param, and rejections" {
    try std.testing.expectEqual(@as(?[]const u8, null), matchPath("/api/v1/system", "/api/v1/system").?);
    try std.testing.expect(matchPath("/api/v1/system", "/api/v1/systemx") == null);
    const bound = matchPath("/api/v1/operations/{id}", "/api/v1/operations/op-3").?;
    try std.testing.expectEqualStrings("op-3", bound.?);
    // Empty and deeper segments do not match a single trailing param.
    try std.testing.expect(matchPath("/api/v1/operations/{id}", "/api/v1/operations/") == null);
    try std.testing.expect(matchPath("/api/v1/operations/{id}", "/api/v1/operations") == null);
    try std.testing.expect(matchPath("/api/v1/operations/{id}", "/api/v1/operations/op-3/logs") == null);
}

test "unwired events/operations answer 501; param routes bind ctx.param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();

    // No event bus / registry is constructed under unit tests, so these
    // routes take the notImplemented path. The /update/* handlers have
    // their own no-manager (503) tests in update.zig.
    const stub_cases = [_]struct { m: Method, p: []const u8 }{
        .{ .m = .GET, .p = "/api/v1/events" },
        .{ .m = .GET, .p = "/api/v1/operations" },
        .{ .m = .GET, .p = "/api/v1/operations/op-3" },
    };
    for (stub_cases) |case| {
        var ctx = testCtx(arena.allocator(), &st, case.m, case.p);
        const resp = dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 501), resp.status);
        try std.testing.expectEqualStrings(problem.content_type, resp.content_type);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "urn:astro:problem:not-implemented") != null);
    }

    // The param binds; a deeper path under the param route is a 404.
    var pctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/operations/op-3");
    _ = dispatch(&pctx);
    try std.testing.expectEqualStrings("op-3", pctx.param.?);
    var deep = testCtx(arena.allocator(), &st, .GET, "/api/v1/operations/op-3/logs");
    try std.testing.expectEqual(@as(u16, 404), dispatch(&deep).status);
    // Wrong method on a stub path is 405, proving path_known still works.
    var wrong = testCtx(arena.allocator(), &st, .DELETE, "/api/v1/update/status");
    try std.testing.expectEqual(@as(u16, 405), dispatch(&wrong).status);
}

test "operations routes serve the registry when wired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();

    var reg = ops.Registry.init(std.testing.allocator);
    defer reg.deinit();
    ops.global = &reg;
    defer ops.global = null;
    const id = try reg.create(.update_install);
    reg.update(id, .running, 40, "Copying image");

    var list_ctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/operations");
    const list_resp = dispatch(&list_ctx);
    try std.testing.expectEqual(@as(u16, 200), list_resp.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), list_resp.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const op0 = parsed.value.array.items[0].object;
    try std.testing.expectEqualStrings("op-1", op0.get("id").?.string);
    try std.testing.expectEqualStrings("update_install", op0.get("kind").?.string);
    try std.testing.expectEqualStrings("running", op0.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 40), op0.get("progress").?.integer);
    // The @"error" field must serialize under the wire name "error".
    try std.testing.expect(op0.get("error") != null);
    try std.testing.expect(op0.get("error").? == .null);

    var one_ctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/operations/op-1");
    try std.testing.expectEqual(@as(u16, 200), dispatch(&one_ctx).status);
    var missing_ctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/operations/op-99");
    const missing = dispatch(&missing_ctx);
    try std.testing.expectEqual(@as(u16, 404), missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "urn:astro:problem:not-found") != null);
}

test "network group: every phase-3 route answers 501 problem+json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();

    const cases = [_]struct { m: Method, p: []const u8 }{
        .{ .m = .GET, .p = "/api/v1/network" },
        .{ .m = .GET, .p = "/api/v1/network/ethernet/eth0" },
        .{ .m = .PUT, .p = "/api/v1/network/ethernet/eth0" },
        .{ .m = .PATCH, .p = "/api/v1/network/ethernet/eth0" },
        .{ .m = .GET, .p = "/api/v1/network/wifi" },
        .{ .m = .POST, .p = "/api/v1/network/wifi/scan" },
        .{ .m = .GET, .p = "/api/v1/network/wifi/networks" },
        .{ .m = .GET, .p = "/api/v1/network/wifi/connection" },
        .{ .m = .PUT, .p = "/api/v1/network/wifi/connection" },
        .{ .m = .DELETE, .p = "/api/v1/network/wifi/connection" },
        .{ .m = .GET, .p = "/api/v1/network/wan" },
        .{ .m = .PUT, .p = "/api/v1/network/wan" },
        .{ .m = .GET, .p = "/api/v1/network/cellular" },
        .{ .m = .PUT, .p = "/api/v1/network/cellular" },
    };
    for (cases) |case| {
        var ctx = testCtx(arena.allocator(), &st, case.m, case.p);
        const resp = dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 501), resp.status);
        try std.testing.expectEqualStrings(problem.content_type, resp.content_type);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "urn:astro:problem:not-implemented") != null);
    }

    // The {iface} param binds; ethernet without an iface is 404 (matchPath
    // rejects empty/deeper segments); wrong verbs on known paths are 405.
    var pctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/network/ethernet/eth0");
    _ = dispatch(&pctx);
    try std.testing.expectEqualStrings("eth0", pctx.param.?);
    var noiface = testCtx(arena.allocator(), &st, .GET, "/api/v1/network/ethernet/");
    try std.testing.expectEqual(@as(u16, 404), dispatch(&noiface).status);
    var wrong = testCtx(arena.allocator(), &st, .DELETE, "/api/v1/network/wan");
    try std.testing.expectEqual(@as(u16, 405), dispatch(&wrong).status);
    var wrong2 = testCtx(arena.allocator(), &st, .POST, "/api/v1/network/cellular");
    try std.testing.expectEqual(@as(u16, 405), dispatch(&wrong2).status);

    // The reserved namespace documents its roadmap in the problem detail.
    var cell = testCtx(arena.allocator(), &st, .GET, "/api/v1/network/cellular");
    const cell_resp = dispatch(&cell);
    try std.testing.expect(std.mem.indexOf(u8, cell_resp.body, "reserved namespace") != null);
}

test "power actions answer 503 problem+json when dinit is unreachable" {
    // No dinit control socket exists under `zig build test`, so the
    // requestShutdown connect fails — the mapped result must be 503.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();
    var ctx = testCtx(arena.allocator(), &st, .POST, "/api/v1/system/reboot");
    const resp = dispatch(&ctx);
    try std.testing.expectEqual(@as(u16, 503), resp.status);
    try std.testing.expectEqualStrings(problem.content_type, resp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "urn:astro:problem:dinit-unavailable") != null);
}
