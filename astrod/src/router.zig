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
const auth = @import("auth.zig");
const portal = @import("portal.zig");
const wifi_mod = @import("wifi.zig");
const provision = @import("provision.zig");
const fsutil = @import("fsutil.zig");

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
    /// Location header for 3xx answers (the captive-probe redirects on
    /// the AP surface are the only writers today).
    location: ?[]const u8 = null,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    request: Request,
    store: *store_mod.Store,
    /// Which listener this request arrived on (AD-014). Defaults to the
    /// most-privileged surface so every pre-phase-4 unit test (and the
    /// unix socket path) keeps its exact prior behavior; main.zig tags
    /// it per connection.
    surface: auth.Surface = .unix,
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
    /// POST /system/factory-reset accepted: dispatch the
    /// astro-factory-reset root oneshot (flag + sync + reboot) with the
    /// 202 already on the wire — same discipline as shutdown.
    factory_reset,
    /// PUT wifi/connection on the AP surface with the AP up: run the
    /// synchronous AP→station flip (provision.Manager.flipConnect)
    /// AFTER the 202 is written — the flip tears the very listener/
    /// address this response leaves on down. Slices are arena-owned
    /// (valid until the connection thread finishes the action).
    wifi_flip: struct { ssid: []const u8, psk: []const u8 },
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
    // Phase-4 provisioning group (docs/06 §5.1/§5.2, docs/07 §4–§5).
    // Without their backends (wifi.global / provision.global null —
    // unit builds) these answer 501 like the network group. PUT
    // /network/wifi/ap and POST /system/factory-reset are deliberately
    // absent from the AP subset (ap_allowed below), so on the AP
    // surface they answer 403.
    .{ .method = .GET, .path = "/api/v1/network/wifi/ap", .handler = getWifiAp },
    .{ .method = .PUT, .path = "/api/v1/network/wifi/ap", .handler = putWifiAp },
    .{ .method = .POST, .path = "/api/v1/system/factory-reset", .handler = postFactoryReset },
};

/// The AD-014 unauthenticated SUBSET served on the AP provisioning
/// surface (docs/06 §6 table, docs/07 §4 item 2): exactly what the
/// captive portal needs — a redacted system summary and the wifi
/// scan/join flow. EVERYTHING else on that surface answers 403 (see
/// dispatch). Keep this list in lockstep with the portal page
/// (src/portal.html) and the spec's AP-surface notes.
pub const ap_allowed_routes = [_]struct { method: Method, path: []const u8 }{
    .{ .method = .GET, .path = "/api/v1/system" }, // redacted — see getSystem
    .{ .method = .POST, .path = "/api/v1/network/wifi/scan" },
    .{ .method = .GET, .path = "/api/v1/network/wifi/networks" },
    .{ .method = .PUT, .path = "/api/v1/network/wifi/connection" },
};

pub fn apAllowed(method: Method, path: []const u8) bool {
    for (ap_allowed_routes) |r| {
        if (r.method == method and std.mem.eql(u8, r.path, path)) return true;
    }
    return false;
}

/// Portal-only routes, served EXCLUSIVELY on the AP surface: the
/// provisioning page and the OS captive-probe paths (docs/07 §4 items
/// 2–3). CONFORMANCE HANDLING (AD-013, explicit decision): these paths
/// are NOT part of the /api/v1 contract — they are captive-portal
/// furniture whose shapes are dictated by phone OSes, not by us — so
/// they live in this separate table, outside `routes`, and outside the
/// spec↔route gate. A conformance test pins the invariant that keeps
/// this sound: no portal route may ever start with /api/ (it could
/// otherwise shadow a documented operation on the AP surface).
pub const portal_routes: []const Route = &.{
    .{ .method = .GET, .path = "/", .handler = portal.getPortalPage },
    .{ .method = .GET, .path = "/generate_204", .handler = portal.probeRedirect },
    .{ .method = .GET, .path = "/hotspot-detect.html", .handler = portal.probeRedirect },
    .{ .method = .GET, .path = "/connecttest.txt", .handler = portal.probeRedirect },
    .{ .method = .GET, .path = "/ncsi.txt", .handler = portal.probeRedirect },
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
///
/// Surface gating (AD-014): on the AP surface, portal_routes are tried
/// first (page + captive probes), then only the ap_allowed subset of the
/// API — anything else is 403 (not 404: the paths exist, this surface
/// refuses them, and hiding that would only confuse portal debugging).
/// On every other surface portal_routes do not exist at all, so
/// pre-phase-4 behavior is bit-identical there.
pub fn dispatch(ctx: *Context) Response {
    if (ctx.surface == .ap) {
        for (portal_routes) |route| {
            if (route.method == ctx.request.method and std.mem.eql(u8, route.path, ctx.request.path)) {
                return route.handler(ctx) catch problemResponse(ctx, .{
                    .type = "urn:astro:problem:internal",
                    .title = "Internal Server Error",
                    .status = 500,
                });
            }
        }
        if (!apAllowed(ctx.request.method, ctx.request.path)) {
            return problemResponse(ctx, .{
                .type = "urn:astro:problem:forbidden",
                .title = "Forbidden",
                .status = 403,
                .detail = "the AP provisioning surface serves only the unauthenticated subset (docs/06 \u{a7}6): GET /api/v1/system, POST /api/v1/network/wifi/scan, GET /api/v1/network/wifi/networks, PUT /api/v1/network/wifi/connection, and the portal page",
            });
        }
    }
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
    // Redaction hook (AD-014): the AP provisioning surface never sees
    // machine_id (it seeds the AP PSK and confirms factory reset).
    if (ctx.surface == .ap) {
        return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, system.redact(info), .{}) };
    }
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, info, .{}) };
}

const machine_id_path = "/etc/machine-id";

/// The docs/02 §7 residual-root-ops oneshot POST /system/factory-reset
/// dispatches (boards/common/overlay/etc/dinit.d/astro-factory-reset).
pub const factory_reset_service = "astro-factory-reset";

/// WifiApState assembly (docs/06 §5.2): enabled from the live
/// AccessPoint.Started mirror, ssid from the same machine-id derivation
/// the radio beacons, subnet from the baked pool. The PSK is NEVER
/// served over HTTP — `astroctl wifi ap show` derives it locally on the
/// socket-only surface (the label story).
fn wifiApStateResponse(ctx: *Context) anyerror!Response {
    const w = wifi_mod.global.?;
    var mid_buf: [128]u8 = undefined;
    var ssid_buf: [32]u8 = undefined;
    var ssid: []const u8 = "";
    if (fsutil.readFileBounded(machine_id_path, &mid_buf)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) ssid = wifi_mod.deriveApSsid(&ssid_buf, trimmed);
    } else |_| {}
    const View = struct { enabled: bool, ssid: []const u8, subnet: []const u8 };
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, View{
        .enabled = w.apActive(),
        .ssid = ssid,
        .subnet = portal.ap_subnet,
    }, .{}) };
}

/// GET /api/v1/network/wifi/ap — AP state {enabled, ssid, subnet}.
/// 501 while the wifi backend is absent (unit builds, radio-less
/// boards), matching the network-group degradation contract.
fn getWifiAp(ctx: *Context) anyerror!Response {
    if (wifi_mod.global == null) return notImplemented(ctx);
    return wifiApStateResponse(ctx);
}

/// PUT /api/v1/network/wifi/ap — the manual tri-state override
/// (docs/06 §5.2 WifiApConfig): true forces the AP up (even with
/// ethernet carrier), false forces it down, null returns control to the
/// provisioning machine. Persisted as system.ap.enabled_override; the
/// machine applies it on its next observation (poked here).
/// Authenticated surfaces only — the AP subset excludes this route.
fn putWifiAp(ctx: *Context) anyerror!Response {
    if (wifi_mod.global == null or provision.global == null) return notImplemented(ctx);
    // Strict body (AD-013): exactly {"enabled": true|false|null}.
    const invalid_detail = "body must be {\"enabled\": true|false|null} (docs/06 \u{a7}5.2 WifiApConfig); unknown members are rejected";
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.request.body, .{}) catch
        return badRequestProblem(ctx, invalid_detail);
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 1)
        return badRequestProblem(ctx, invalid_detail);
    const enabled_v = parsed.value.object.get("enabled") orelse
        return badRequestProblem(ctx, invalid_detail);
    const override: ?bool = switch (enabled_v) {
        .bool => |b| b,
        .null => null,
        else => return badRequestProblem(ctx, invalid_detail),
    };
    ctx.store.setApEnabledOverride(override) catch return problemResponse(ctx, .{
        .type = "urn:astro:problem:store-failed",
        .title = "Internal Server Error",
        .status = 500,
        .detail = "persisting system.ap.enabled_override failed",
    });
    provision.global.?.pokeObserve();
    return wifiApStateResponse(ctx);
}

fn badRequestProblem(ctx: *Context, detail: []const u8) Response {
    return problemResponse(ctx, .{
        .type = "urn:astro:problem:bad-request",
        .title = "Bad Request",
        .status = 400,
        .detail = detail,
    });
}

/// POST /api/v1/system/factory-reset — confirm-with-serial (docs/06
/// §5.1): {"confirm": "<machine-id>"} must match this device, then the
/// astro-factory-reset root oneshot (flag + sync + reboot; data-mount
/// wipes /data on the way back up — docs/07 §5) is dispatched AFTER the
/// 202 is on the wire (deferred discipline). dinit and the service are
/// probed before answering so failures still surface as HTTP errors.
fn postFactoryReset(ctx: *Context) anyerror!Response {
    if (provision.global == null) return notImplemented(ctx);
    const Body = struct { confirm: []const u8 };
    const body = std.json.parseFromSliceLeaky(Body, ctx.allocator, ctx.request.body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return badRequestProblem(ctx, "body must be {\"confirm\": \"<machine-id>\"} (docs/06 \u{a7}5.1 confirm-with-serial); unknown members are rejected"),
    };
    var mid_buf: [128]u8 = undefined;
    const mid: []const u8 = blk: {
        const text = fsutil.readFileBounded(machine_id_path, &mid_buf) catch "";
        break :blk std.mem.trim(u8, text, " \t\r\n");
    };
    if (mid.len == 0) return problemResponse(ctx, .{
        .type = "urn:astro:problem:internal",
        .title = "Internal Server Error",
        .status = 500,
        .detail = "machine-id unavailable; the confirm token cannot be verified",
    });
    if (!std.mem.eql(u8, mid, body.confirm)) {
        return badRequestProblem(ctx, "confirm does not match this device's machine_id (GET /api/v1/system on an authenticated surface)");
    }
    // Probe: dinit reachable AND the oneshot loadable — after the 202
    // there is no error channel left (same TOCTOU stance as powerAction).
    var probe = dinit.Client.connect(dinit.default_socket_path) catch return problemResponse(ctx, .{
        .type = "urn:astro:problem:dinit-unavailable",
        .title = "Service Unavailable",
        .status = 503,
        .detail = "cannot reach the dinit control socket",
    });
    defer probe.deinit();
    _ = probe.loadService(factory_reset_service) catch return problemResponse(ctx, .{
        .type = "urn:astro:problem:internal",
        .title = "Internal Server Error",
        .status = 500,
        .detail = "the astro-factory-reset service is not loadable",
    });
    ctx.deferred = .factory_reset;
    return .{ .status = 202, .body = "{\"operation\":null}" };
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

test "phase-4 routes answer 501 problem+json on default surfaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();

    const cases = [_]struct { m: Method, p: []const u8 }{
        .{ .m = .GET, .p = "/api/v1/network/wifi/ap" },
        .{ .m = .PUT, .p = "/api/v1/network/wifi/ap" },
        .{ .m = .POST, .p = "/api/v1/system/factory-reset" },
    };
    for (cases) |case| {
        var ctx = testCtx(arena.allocator(), &st, case.m, case.p);
        const resp = dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 501), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "urn:astro:problem:not-implemented") != null);
    }
    // Wrong verbs are 405 (the paths are known).
    var wrong = testCtx(arena.allocator(), &st, .DELETE, "/api/v1/network/wifi/ap");
    try std.testing.expectEqual(@as(u16, 405), dispatch(&wrong).status);
    var wrong2 = testCtx(arena.allocator(), &st, .GET, "/api/v1/system/factory-reset");
    try std.testing.expectEqual(@as(u16, 405), dispatch(&wrong2).status);
}

fn apCtx(allocator: std.mem.Allocator, st: *store_mod.Store, method: Method, path: []const u8) Context {
    var ctx = testCtx(allocator, st, method, path);
    ctx.surface = .ap;
    return ctx;
}

test "AP surface serves exactly the unauthenticated subset, 403 otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();

    // Subset members reach their handlers (unit build: network handlers
    // answer 501 not-wired, which proves dispatch let them through; the
    // 403 gate would have preempted them).
    const allowed = [_]struct { m: Method, p: []const u8, want: u16 }{
        .{ .m = .GET, .p = "/api/v1/system", .want = 200 },
        .{ .m = .POST, .p = "/api/v1/network/wifi/scan", .want = 501 },
        .{ .m = .GET, .p = "/api/v1/network/wifi/networks", .want = 501 },
        .{ .m = .PUT, .p = "/api/v1/network/wifi/connection", .want = 501 },
    };
    for (allowed) |case| {
        var ctx = apCtx(arena.allocator(), &st, case.m, case.p);
        try std.testing.expectEqual(case.want, dispatch(&ctx).status);
    }

    // Everything else on the AP surface is 403 — including the
    // authenticated-only phase-4 endpoints, sensitive reads, and
    // methods that are fine on other surfaces.
    const forbidden = [_]struct { m: Method, p: []const u8 }{
        .{ .m = .PUT, .p = "/api/v1/network/wifi/ap" },
        .{ .m = .GET, .p = "/api/v1/network/wifi/ap" },
        .{ .m = .POST, .p = "/api/v1/system/factory-reset" },
        .{ .m = .POST, .p = "/api/v1/system/reboot" },
        .{ .m = .POST, .p = "/api/v1/update" },
        .{ .m = .GET, .p = "/api/v1/update/status" },
        .{ .m = .GET, .p = "/api/v1/network/wifi/connection" }, // GET is not in the subset
        .{ .m = .DELETE, .p = "/api/v1/network/wifi/connection" },
        .{ .m = .GET, .p = "/api/v1/events" },
        .{ .m = .GET, .p = "/api/v1/openapi.json" },
        .{ .m = .GET, .p = "/api/v1/totally/unknown" }, // even unknown paths: 403, not 404
    };
    for (forbidden) |case| {
        var ctx = apCtx(arena.allocator(), &st, case.m, case.p);
        const resp = dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 403), resp.status);
        try std.testing.expectEqualStrings(problem.content_type, resp.content_type);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "urn:astro:problem:forbidden") != null);
    }
}

test "AP surface: portal page, captive probes, and the redaction hook" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();

    // GET / serves the embedded portal page on the AP surface…
    var page_ctx = apCtx(arena.allocator(), &st, .GET, "/");
    const page_resp = dispatch(&page_ctx);
    try std.testing.expectEqual(@as(u16, 200), page_resp.status);
    try std.testing.expect(std.mem.startsWith(u8, page_resp.content_type, "text/html"));

    // …and every OS probe path 302s to it (Location header).
    for (portal.probe_paths) |p| {
        var ctx = apCtx(arena.allocator(), &st, .GET, p);
        const resp = dispatch(&ctx);
        try std.testing.expectEqual(@as(u16, 302), resp.status);
        try std.testing.expectEqualStrings("/", resp.location.?);
    }

    // GET /system on the AP surface is REDACTED: no machine_id, but
    // provisioning/release survive (the portal shows them).
    var sys_ctx = apCtx(arena.allocator(), &st, .GET, "/api/v1/system");
    const sys_resp = dispatch(&sys_ctx);
    try std.testing.expectEqual(@as(u16, 200), sys_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, sys_resp.body, "machine_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, sys_resp.body, "\"provisioning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_resp.body, "\"time_synced\"") != null);
}

test "existing surfaces are unchanged: no portal routes, no redaction, no 403s" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var st = try testStore();
    defer st.deinit();

    // GET / stays 404 on the unix surface (portal routes are AP-only).
    var root_ctx = testCtx(arena.allocator(), &st, .GET, "/");
    try std.testing.expectEqual(@as(u16, 404), dispatch(&root_ctx).status);
    var probe_ctx = testCtx(arena.allocator(), &st, .GET, "/generate_204");
    try std.testing.expectEqual(@as(u16, 404), dispatch(&probe_ctx).status);

    // GET /system keeps machine_id on unix and localhost surfaces.
    var unix_ctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/system");
    try std.testing.expect(std.mem.indexOf(u8, dispatch(&unix_ctx).body, "machine_id") != null);
    var local_ctx = testCtx(arena.allocator(), &st, .GET, "/api/v1/system");
    local_ctx.surface = .localhost;
    try std.testing.expect(std.mem.indexOf(u8, dispatch(&local_ctx).body, "machine_id") != null);
}

test "portal routes never shadow the API namespace (conformance invariant)" {
    // The AD-013 gate covers `routes` only; this pins the invariant that
    // keeps the exemption sound — a portal route under /api/ could
    // shadow a documented operation on the AP surface.
    for (portal_routes) |route| {
        try std.testing.expect(!std.mem.startsWith(u8, route.path, "/api/"));
    }
    // And the AP whitelist only names documented routes.
    for (ap_allowed_routes) |allowed| {
        const known = for (routes) |route| {
            if (route.method == allowed.method and std.mem.eql(u8, route.path, allowed.path)) break true;
        } else false;
        try std.testing.expect(known);
    }
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
