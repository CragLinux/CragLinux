//! App-service control surface (docs/06 §5.4, docs/08 §5) — M4 phase-1.
//!
//! The /services group is DELIBERATELY NARROW: it must not become a
//! privilege-escalation bridge to init. astrod exposes only the app services
//! that OPTED IN via their external-tree manifest ([integration]
//! api_controllable = true, docs/08 §5). astrod learns that set by reading the
//! very same manifests the image-assembly hook reads — usr/lib/astro/services/
//! — at startup (loadManifests). A service that is not api_controllable is
//! invisible here: list() omits it and the action endpoints answer 404 (NOT
//! 403 — revealing that a service exists is itself information, router.zig).
//!
//! MANIFEST SIDECARS. The on-disk manifests are TOML (schema.py:
//! SERVICE_MANIFEST_SCHEMA), but std has no TOML parser and astrod avoids
//! shelling out. So the image-assembly hook (40-service-manifests.sh) emits a
//! JSON sidecar `usr/lib/astro/services/<name>.json` beside each `<name>.toml`
//! (the exact ServiceManifest.to_dict() shape); astrod parses THAT with
//! std.json. Only `name` + `api_controllable` are consulted here — the rest of
//! the manifest drives build-time effects, not runtime policy. (Followup to
//! the assembly-hook agent requests the sidecar emission.)
//!
//! Mechanism: state/pid come from the dinit control socket (dinit.zig's
//! SERVICESTATUS5 query); restart/stop/start go through the dinit client's
//! existing verbs. dinit's protocol exposes NO automatic-restart counter in
//! any status buffer, so `restart_count` here is astrod's own count of
//! API-initiated restarts (incremented on a successful POST .../restart) — the
//! honest, implementable reading of docs/06 §5.4's "restart count".
//!
//! `global` is null under unit builds, so the router answers 501 for the whole
//! group exactly like the other unwired subsystems until main.zig constructs +
//! installs the Registry and calls loadManifests at startup.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const dinit = @import("dinit.zig");
const fsutil = @import("fsutil.zig");

/// Rootfs-relative directory the apk-installed manifests + sidecars live in
/// (docs/08 §5). loadManifests joins this onto its rootfs prefix.
pub const services_subdir = "/usr/lib/astro/services";

/// One app-controllable service as GET /api/v1/services reports it (docs/06
/// §5.4): name, dinit state, pid (null when not running), restart count.
pub const ServiceStatus = struct {
    name: []const u8,
    /// dinit service state token: "started" | "stopped" | "starting" |
    /// "stopping", or "unknown" when the service could not be queried.
    state: []const u8,
    pid: ?i32,
    restart_count: u32,
};

pub const Error = error{
    /// The backing subsystem is not wired in this build — router maps it to
    /// 501, matching the other groups' contract. (Retained for the seam
    /// contract; the live registry never returns it.)
    NotWired,
    /// No api_controllable service by that name — router maps it to 404.
    UnknownService,
    /// The dinit control socket could not be reached / spoke wrong — 503.
    DinitUnavailable,
    OutOfMemory,
};

/// The set of api_controllable services, learned from the on-disk sidecars.
/// A single shared instance is installed at `global` by main.zig once the
/// daemon is up; router handlers consult `global` (null => 501).
pub const Registry = struct {
    allocator: std.mem.Allocator,
    /// dinit control socket path (default_socket_path in production).
    socket_path: []const u8 = dinit.default_socket_path,
    /// Owned, sorted list of api_controllable service names.
    controllable_names: []const []const u8 = &.{},
    /// Parallel to controllable_names: count of API-initiated restarts per
    /// service this daemon run (see the restart_count note in the module doc).
    restart_counts: []u32 = &.{},

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// Release the owned name slices + parallel counters. Safe to call on a
    /// never-loaded registry (both slices default to empty).
    pub fn deinit(self: *Registry) void {
        self.freeOwned();
    }

    fn freeOwned(self: *Registry) void {
        for (self.controllable_names) |n| self.allocator.free(n);
        if (self.controllable_names.len > 0) self.allocator.free(self.controllable_names);
        if (self.restart_counts.len > 0) self.allocator.free(self.restart_counts);
        self.controllable_names = &.{};
        self.restart_counts = &.{};
    }

    /// Read the JSON sidecars under `<rootfs_prefix>/usr/lib/astro/services`
    /// and populate controllable_names with the services whose manifest set
    /// api_controllable = true (docs/08 §5). `rootfs_prefix` is "" in
    /// production (=> the absolute /usr/lib/astro/services). A MISSING
    /// directory is the no-app / no-external-tree path and is a clean no-op —
    /// controllable_names stays empty and the group answers empty/404. A
    /// malformed sidecar is SKIPPED (the build side already validated the
    /// TOML), never fatal, so one bad file cannot brick the API at startup.
    pub fn loadManifests(self: *Registry, rootfs_prefix: []const u8) Error!void {
        const dir = std.fmt.allocPrint(self.allocator, "{s}" ++ services_subdir, .{rootfs_prefix}) catch
            return error.OutOfMemory;
        defer self.allocator.free(dir);

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        errdefer for (names.items) |n| self.allocator.free(n);

        try readControllable(self.allocator, dir, &names);
        std.mem.sort([]const u8, names.items, {}, lessName);

        const counts = self.allocator.alloc(u32, names.items.len) catch return error.OutOfMemory;
        @memset(counts, 0);
        const owned = names.toOwnedSlice(self.allocator) catch {
            self.allocator.free(counts);
            return error.OutOfMemory;
        };
        // toOwnedSlice emptied `names`; the errdefer above is now a no-op and
        // `owned` holds every name — install atomically over any prior load.
        self.freeOwned();
        self.controllable_names = owned;
        self.restart_counts = counts;
    }

    fn indexOf(self: *const Registry, name: []const u8) ?usize {
        for (self.controllable_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }

    /// True iff `name` is an api_controllable service (docs/06 §5.4). The
    /// action endpoints gate on this; a false answer becomes a 404.
    pub fn controllable(self: *const Registry, name: []const u8) bool {
        return self.indexOf(name) != null;
    }

    /// GET /api/v1/services — status of every api_controllable service. Opens
    /// one dinit control connection and queries each service in turn; a
    /// per-service query failure degrades that entry to state "unknown" rather
    /// than failing the whole list (the set is authoritative from the
    /// manifests even if a service is momentarily unloaded). Only a failure to
    /// reach dinit at all is DinitUnavailable (-> 503). Result slice is
    /// allocated from `allocator`; the name/state strings are borrowed (names
    /// from the registry, state tokens static), so freeing the slice suffices.
    pub fn list(self: *const Registry, allocator: std.mem.Allocator) Error![]ServiceStatus {
        if (self.controllable_names.len == 0) return &.{};
        var client = dinit.Client.connect(self.socket_path) catch return error.DinitUnavailable;
        defer client.deinit();
        return self.listWith(allocator, &client);
    }

    /// list() over an already-connected client (seam for a scripted fake).
    fn listWith(self: *const Registry, allocator: std.mem.Allocator, client: *dinit.Client) Error![]ServiceStatus {
        const out = allocator.alloc(ServiceStatus, self.controllable_names.len) catch return error.OutOfMemory;
        for (self.controllable_names, self.restart_counts, 0..) |name, rc, i| {
            out[i] = queryOne(client, name, rc);
        }
        return out;
    }

    /// POST /api/v1/services/{name}/restart — gated on controllable(name); a
    /// non-controllable name is UnknownService (-> 404, NOT 403). On success
    /// the per-service restart counter is bumped.
    pub fn restart(self: *Registry, name: []const u8) Error!void {
        const idx = self.indexOf(name) orelse return error.UnknownService;
        dinit.restartServiceByName(self.socket_path, name) catch return error.DinitUnavailable;
        self.restart_counts[idx] +%= 1;
    }

    /// POST /api/v1/services/{name}/stop — gated on controllable(name).
    pub fn stop(self: *const Registry, name: []const u8) Error!void {
        if (!self.controllable(name)) return error.UnknownService;
        dinit.stopServiceByName(self.socket_path, name) catch return error.DinitUnavailable;
    }

    /// POST /api/v1/services/{name}/start — gated on controllable(name).
    pub fn start(self: *const Registry, name: []const u8) Error!void {
        if (!self.controllable(name)) return error.UnknownService;
        dinit.startServiceByName(self.socket_path, name) catch return error.DinitUnavailable;
    }
};

/// Query one service's live status over `client`. Any dinit error degrades to
/// an "unknown"/no-pid entry so a single unloadable service never fails the
/// whole GET /services response.
fn queryOne(client: *dinit.Client, name: []const u8, restart_count: u32) ServiceStatus {
    const degraded = ServiceStatus{ .name = name, .state = "unknown", .pid = null, .restart_count = restart_count };
    const handle = client.loadService(name) catch return degraded;
    const rt = client.serviceStatus(handle) catch return degraded;
    return .{ .name = name, .state = dinit.stateName(rt.state), .pid = rt.pid, .restart_count = restart_count };
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Sidecar shape (a subset of ServiceManifest.to_dict(), docs/08 §5); only the
/// two fields runtime policy needs are declared, the rest ignored.
const Sidecar = struct {
    name: []const u8,
    api_controllable: bool = false,
};

/// Parse one JSON sidecar; returns an allocator-owned copy of the service name
/// when the manifest is api_controllable, else null. error.Parse on malformed
/// JSON (caller skips it), error.OutOfMemory propagates.
fn parseControllableName(allocator: std.mem.Allocator, bytes: []const u8) error{ Parse, OutOfMemory }!?[]const u8 {
    var parsed = std.json.parseFromSlice(Sidecar, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Parse,
    };
    defer parsed.deinit();
    if (!parsed.value.api_controllable or parsed.value.name.len == 0) return null;
    return try allocator.dupe(u8, parsed.value.name);
}

/// Enumerate `dir` for `*.json` sidecars via raw getdents64 (the std.fs dir
/// walker sits behind std.Io, which daemon code avoids — see fsutil.zig /
/// netconf.readLeases) and append every api_controllable service name (owned)
/// to `out`. A missing/unopenable directory yields nothing (no-app path).
fn readControllable(allocator: std.mem.Allocator, dir: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    const dir_z = posix.toPosixPath(dir) catch return; // path too long: treat as absent
    const rc = linux.openat(linux.AT.FDCWD, &dir_z, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(rc) != .SUCCESS) return; // missing dir = no-app / no-external-tree path
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
            const fname = name_bytes[0..name_len];
            off += reclen;
            if (fname.len == 0 or fname[0] == '.') continue;
            if (!std.mem.endsWith(u8, fname, ".json")) continue;

            const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, fname }) catch return error.OutOfMemory;
            defer allocator.free(path);
            const bytes = fsutil.readFileAlloc(allocator, path, 64 * 1024) catch continue;
            defer allocator.free(bytes);

            const svc_name = parseControllableName(allocator, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Parse => continue, // malformed sidecar: skip (TOML already validated at build)
            } orelse continue; // manifest present but not api_controllable
            out.append(allocator, svc_name) catch {
                allocator.free(svc_name);
                return error.OutOfMemory;
            };
        }
    }
}

/// Installed by main.zig once the daemon is up; null under unit builds, so the
/// router answers 501 for the whole group (same contract as netconf/wifi).
pub var global: ?*Registry = null;

// ---- tests -----------------------------------------------------------------

test "empty registry: nothing controllable, actions 404 unknown names" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(!reg.controllable("acme-sensord"));
    // A non-controllable name is UnknownService (router -> 404), never a
    // silent success — the 404-not-403 contract holds even with no manifests.
    try std.testing.expectError(error.UnknownService, reg.restart("acme-sensord"));
    try std.testing.expectError(error.UnknownService, reg.stop("acme-sensord"));
    try std.testing.expectError(error.UnknownService, reg.start("acme-sensord"));
}

test "loadManifests: missing dir is a clean no-op; list is empty" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.loadManifests("/nonexistent-astro-rootfs-xyz");
    try std.testing.expectEqual(@as(usize, 0), reg.controllable_names.len);
    // Empty registry: list() returns an empty slice WITHOUT touching dinit
    // (no socket exists under `zig build test`).
    const got = try reg.list(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "parseControllableName: gates on api_controllable, owns the name" {
    const a = std.testing.allocator;
    // api_controllable true -> owned name; unknown fields ignored.
    const yes = try parseControllableName(a, "{\"name\":\"acme-sensord\",\"api_controllable\":true,\"user\":\"acme\",\"uid\":517}");
    try std.testing.expect(yes != null);
    defer a.free(yes.?);
    try std.testing.expectEqualStrings("acme-sensord", yes.?);
    // Absent / false api_controllable -> null.
    try std.testing.expect((try parseControllableName(a, "{\"name\":\"x\"}")) == null);
    try std.testing.expect((try parseControllableName(a, "{\"name\":\"x\",\"api_controllable\":false}")) == null);
    // Malformed JSON -> Parse (caller skips).
    try std.testing.expectError(error.Parse, parseControllableName(a, "{not json"));
}

// Create every component of an absolute path (std.testing.tmpDir + Dir.makePath
// now sit behind std.Io, which daemon code + its tests avoid; see fsutil.zig).
fn mkdirp(path: []const u8) void {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        buf[len] = '/';
        len += 1;
        @memcpy(buf[len..][0..seg.len], seg);
        len += seg.len;
        const pz = posix.toPosixPath(buf[0..len]) catch return;
        _ = linux.mkdirat(linux.AT.FDCWD, &pz, 0o755);
    }
}

test "loadManifests: globs sidecars, keeps only api_controllable, sorted" {
    var root_buf: [128]u8 = undefined;
    const root = fsutil.testTmpPath(&root_buf, "root");
    var dir_buf: [256]u8 = undefined;
    const svc_dir = std.fmt.bufPrint(&dir_buf, "{s}" ++ services_subdir, .{root}) catch unreachable;
    mkdirp(svc_dir);

    // Two controllable (out of order on disk), one not, one non-.json noise.
    const files = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "zeta.json", .data = "{\"name\":\"zeta\",\"api_controllable\":true}" },
        .{ .name = "alpha.json", .data = "{\"name\":\"alpha\",\"api_controllable\":true}" },
        .{ .name = "beta.json", .data = "{\"name\":\"beta\",\"api_controllable\":false}" },
        .{ .name = "beta.toml", .data = "ignored = true" },
    };
    var fpath_buf: [320]u8 = undefined;
    for (files) |f| {
        const fp = std.fmt.bufPrint(&fpath_buf, "{s}/{s}", .{ svc_dir, f.name }) catch unreachable;
        try fsutil.writeFileSync(fp, f.data);
    }
    defer for (files) |f| {
        var b: [320]u8 = undefined;
        const fp = std.fmt.bufPrint(&b, "{s}/{s}", .{ svc_dir, f.name }) catch unreachable;
        fsutil.unlink(fp) catch {};
    };

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.loadManifests(root);

    try std.testing.expectEqual(@as(usize, 2), reg.controllable_names.len);
    try std.testing.expectEqualStrings("alpha", reg.controllable_names[0]); // sorted
    try std.testing.expectEqualStrings("zeta", reg.controllable_names[1]);
    try std.testing.expect(reg.controllable("alpha"));
    try std.testing.expect(reg.controllable("zeta"));
    try std.testing.expect(!reg.controllable("beta"));
    // Counters allocated parallel and zeroed.
    try std.testing.expectEqual(@as(usize, 2), reg.restart_counts.len);
    try std.testing.expectEqual(@as(u32, 0), reg.restart_counts[0]);
}

test "listWith: shapes state/pid/restart_count from scripted dinit replies" {
    var reg = Registry.init(std.testing.allocator);
    // Bypass loadManifests: install two known-order names + a live counter
    // (no allocator-owned memory, so no deinit).
    const names = [_][]const u8{ "svc-a", "svc-b" };
    var counts = [_]u32{ 3, 0 };
    reg.controllable_names = &names;
    reg.restart_counts = &counts;

    var server: posix.fd_t = undefined;
    var client = try testPair(&server);
    defer client.deinit();
    defer _ = linux.close(server);

    // svc-a: SERVICERECORD (state,handle=1,target) then SERVICESTATUS
    // (STARTED, pid=42). svc-b: handle=2, then STOPPED with no pid.
    try feed(server, &.{ 59, 2, 1, 0, 0, 0, 2 });
    try feed(server, &.{ 70, 0, 2, 2, 16, 0, 0, 0, 0x2a, 0, 0, 0, 0, 0, 0, 0 });
    try feed(server, &.{ 59, 0, 2, 0, 0, 0, 0 });
    try feed(server, &.{ 70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

    const got = try reg.listWith(std.testing.allocator, &client);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("svc-a", got[0].name);
    try std.testing.expectEqualStrings("started", got[0].state);
    try std.testing.expectEqual(@as(?i32, 42), got[0].pid);
    try std.testing.expectEqual(@as(u32, 3), got[0].restart_count); // surfaced from the counter
    try std.testing.expectEqualStrings("svc-b", got[1].name);
    try std.testing.expectEqualStrings("stopped", got[1].state);
    try std.testing.expectEqual(@as(?i32, null), got[1].pid);
    try std.testing.expectEqual(@as(u32, 0), got[1].restart_count);
}

test "queryOne: a dinit error degrades to unknown, never fails the list" {
    var reg = Registry.init(std.testing.allocator);
    const names = [_][]const u8{"svc-x"};
    var counts = [_]u32{7};
    reg.controllable_names = &names;
    reg.restart_counts = &counts;

    var server: posix.fd_t = undefined;
    var client = try testPair(&server);
    defer client.deinit();
    defer _ = linux.close(server);

    // loadService gets NOSERVICE -> the entry degrades but still appears.
    try feed(server, &.{60});
    const got = try reg.listWith(std.testing.allocator, &client);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("svc-x", got[0].name);
    try std.testing.expectEqualStrings("unknown", got[0].state);
    try std.testing.expectEqual(@as(?i32, null), got[0].pid);
    try std.testing.expectEqual(@as(u32, 7), got[0].restart_count);
}

// A scripted socketpair stands in for the daemon (mirrors dinit.zig's test
// harness): replies are pre-written into the peer buffer, the client reads
// them; the client's own request bytes accumulate unread in the other
// direction. Small frames never fill the buffer, so nothing blocks.
fn testPair(server_fd: *posix.fd_t) !dinit.Client {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds)) != .SUCCESS)
        return error.SkipZigTest;
    server_fd.* = fds[1];
    return .{ .fd = fds[0] };
}

fn feed(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS) return error.TestWriteFailed;
        off += rc;
    }
}
