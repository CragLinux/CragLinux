//! Route table + dispatch. The table is a comptime slice so CI can verify
//! handlers and openapi.yaml never diverge (AD-013 "spec-driven route
//! table") — see the conformance test at the bottom.

const std = @import("std");
const problem = @import("problem.zig");
const system = @import("system.zig");
const dinit = @import("dinit.zig");
const store_mod = @import("store.zig");

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
    /// Path only — query string already stripped by the HTTP layer.
    path: []const u8,
    authorization: ?[]const u8 = null,
    body: []const u8 = "",
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
    /// Action the connection layer must run AFTER the response is on the
    /// wire. Power actions cannot run inline: dinit begins teardown (and
    /// kills astrod) immediately, so an inline SHUTDOWN raced the 202 and
    /// clients saw a truncated response (observed on qemu-armv7).
    deferred: ?DeferredAction = null,
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
pub const routes: []const Route = &.{
    .{ .method = .GET, .path = "/api/v1/system", .handler = getSystem },
    .{ .method = .POST, .path = "/api/v1/system/reboot", .handler = postReboot },
    .{ .method = .POST, .path = "/api/v1/system/poweroff", .handler = postPoweroff },
    .{ .method = .GET, .path = "/api/v1/openapi.json", .handler = getOpenapi },
};

/// Never returns an error: handler failures become 500 problem+json so the
/// connection layer always has something well-formed to write.
pub fn dispatch(ctx: *Context) Response {
    var path_known = false;
    for (routes) |route| {
        if (std.mem.eql(u8, route.path, ctx.request.path)) {
            path_known = true;
            if (route.method == ctx.request.method) {
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
    const info = system.collectWith(ctx.store.getProvisioning());
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
