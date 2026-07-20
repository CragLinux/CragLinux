//! The update endpoint group (docs/06 §5.3) + install lifecycle manager:
//! glue between HTTP handlers, the rauc.zig D-Bus client, the operations
//! registry (ops.zig) and the event bus (events.zig).
//!
//! AD-021 (docs/05 §6): astrod refuses to install a bundle whose version
//! is lower than the running release unless the request carries
//! {"force": true}. The gate is signature-first: versions come from
//! InspectBundle, which verifies against the device keyring before any
//! manifest data is reported. Coverage:
//!   - staged uploads and local-path installs: InspectBundle + gate.
//!   - http(s) URL installs go straight to InstallBundle — RAUC streams
//!     the bundle itself and exposes no pre-install metadata for remote
//!     sources, so the version gate DOES NOT run for URL installs.
//!     Recorded v1 limitation (documented in the OpenAPI spec); operators
//!     who need the gate download first and POST the file (or the raw
//!     bytes) instead.
//!   - a refused upload is kept in staging; the 409 problem detail names
//!     the staged path so the client can force-install it via
//!     {"url": "<staged path>", "force": true} without re-uploading.
//!
//! Threading/locking (must hold under the threaded server + bus thread):
//!   - install_mu serializes install admission on HTTP handler threads;
//!     it IS held across the InstallBundle bus call and must therefore
//!     NEVER be taken on the bus thread.
//!   - op_mu is a LEAF lock guarding current-op/staged-path/history. It
//!     is taken by bus-thread signal callbacks (which run with the bus
//!     mutex held), so no bus call may ever happen while holding it —
//!     that ordering (bus.mu -> op_mu here, mgr locks -> bus.mu there)
//!     would deadlock. registry.mu and events.mu are leaf locks too.
//!
//! The route table entries live in router.zig (shared file): the
//! followup wires GET /update/status, POST /update, POST /update/apply
//! and POST /update/rollback to the pub handlers below and constructs
//! the Manager in main.zig after the store loads.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const router = @import("router.zig");
const problem = @import("problem.zig");
const bus_mod = @import("bus.zig");
const rauc = @import("rauc.zig");
const ops = @import("ops.zig");
const events_mod = @import("events.zig");
const version = @import("version.zig");
const sync = @import("sync.zig");
const dinit = @import("dinit.zig");
const fsutil = @import("fsutil.zig");
const store_mod = @import("store.zig");

/// docs/05 §5.1: uploads are staged here (on /data, which both slots
/// share) before RAUC gets the local path.
pub const default_staging_dir = "/data/.astro/staging";

/// Free space demanded beyond the upload itself: RAUC needs scratch for
/// mount/verity work, and filling /data to the last byte would starve the
/// store's atomic-write tempfiles.
pub const staging_margin_bytes: u64 = 1 * 1024 * 1024;

pub const max_history = 16;

/// Set by main.zig once the D-Bus spine is up (followup); handlers answer
/// 503 rauc-unavailable while null, so the API degrades cleanly when
/// dbus-daemon/rauc are absent.
pub var manager: ?*Manager = null;

// ---- AD-021 gate ------------------------------------------------------------

pub const GateDecision = enum { allow, refuse, forced };

/// The monotonic-version gate. An empty candidate version (bundle without
/// update.version) is treated as a downgrade — unknown must not slip past
/// the gate — but stays force-installable for field recovery.
pub fn versionGate(candidate: []const u8, running: []const u8, force: bool) GateDecision {
    if (candidate.len > 0 and !version.isDowngrade(candidate, running)) return .allow;
    return if (force) .forced else .refuse;
}

// ---- pure status predicates -------------------------------------------------

/// A pending update = the bootloader's primary slot is not the slot we
/// booted from (RAUC marks the freshly installed slot primary at the end
/// of a successful install; the switch happens at the next reboot).
/// Compared in slot-name space via the slots list — the BootSlot property
/// is a bootname/device, not a slot name.
pub fn hasPendingSlot(st: rauc.Status) bool {
    const primary = st.primary orelse return false;
    if (primary.len == 0) return false;
    for (st.slots) |s| {
        if (std.mem.eql(u8, s.state, "booted"))
            return !std.mem.eql(u8, s.name, primary);
    }
    return false;
}

/// Rollback is only valid while the other slot still holds the prior
/// release (docs/05 §5.1): some non-booted slot must have a slot status
/// with a bundle version (i.e. has ever been installed).
pub fn isRollbackable(st: rauc.Status) bool {
    for (st.slots) |s| {
        if (!std.mem.eql(u8, s.state, "booted") and s.bundle_version.len > 0)
            return true;
    }
    return false;
}

// ---- request parsing --------------------------------------------------------

/// JSON body of POST /update. Unknown fields are rejected (docs/06 §4
/// compat contract: surface client typos early).
pub const InstallRequest = struct {
    url: ?[]const u8 = null,
    force: bool = false,
    /// docs/05 §5.1 reserves {"apply": "auto"}; not implemented in v1 —
    /// sending it is a 400 with an explicit detail, not a silent ignore.
    apply: ?[]const u8 = null,
};

pub fn parseInstallRequest(allocator: std.mem.Allocator, body: []const u8) ?InstallRequest {
    return std.json.parseFromSliceLeaky(InstallRequest, allocator, body, .{}) catch null;
}

/// True when the raw query string carries `name` as a truthy flag
/// ("force=true", "force=1", or bare "force"). The spec documents
/// ?force=true on POST /update: the octet-stream form has no JSON body
/// to carry {"force": true}, and the JSON form ORs it with the body
/// field.
pub fn queryFlag(query: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            if (std.mem.eql(u8, pair, name)) return true;
            continue;
        };
        if (std.mem.eql(u8, pair[0..eq], name)) {
            const v = pair[eq + 1 ..];
            return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        }
    }
    return false;
}

/// The signal body of org.freedesktop.DBus.Properties.PropertiesChanged
/// is (s interface, a{sv} changed, as invalidated). Returns the Progress
/// value when the RAUC installer interface changed it, null otherwise.
/// The message string is borrowed from the reader. The trailing "as" is
/// deliberately left unread.
pub const ProgressChange = struct {
    percentage: i32,
    message: []const u8,
    depth: i32,
};

pub fn parseProgressChange(reader: anytype) bus_mod.Error!?ProgressChange {
    const iface = try reader.readString();
    if (!std.mem.eql(u8, iface, rauc.interface)) return null;
    var found: ?ProgressChange = null;
    if (!try reader.enterContainer('a', "{sv}")) return null;
    while (try reader.enterContainer('e', "sv")) {
        const key = try reader.readString();
        if (std.mem.eql(u8, key, "Progress")) {
            // Progress is (isi): percentage, message, nesting depth —
            // pinned to the rauc-1.15.2 XML (NOT (iis)).
            if (!try reader.enterContainer('v', "(isi)")) return error.InvalidReply;
            if (!try reader.enterContainer('r', "isi")) return error.InvalidReply;
            const pct = try reader.readI32();
            const msg = try reader.readString();
            const depth = try reader.readI32();
            try reader.exitContainer(); // struct
            try reader.exitContainer(); // variant
            found = .{ .percentage = pct, .message = msg, .depth = depth };
        } else {
            try reader.skip("v");
        }
        try reader.exitContainer(); // dict entry
    }
    try reader.exitContainer(); // changed-properties array
    return found;
}

fn clampPct(p: i32) u8 {
    return @intCast(@min(100, @max(0, p)));
}

// ---- free-space check (statvfs family) --------------------------------------

/// Available bytes for unprivileged writers on the filesystem holding
/// `dir`; null when the probe fails (the caller then skips the pre-check
/// and relies on the write itself failing). Raw syscall: Zig 0.16's std
/// has no statfs wrapper. 32-bit ARM uses statfs64 (packed,aligned(4)
/// kernel ABI); the 64-bit arches share the asm-generic layout.
pub fn freeBytes(dir: []const u8) ?u64 {
    const path_z = std.posix.toPosixPath(dir) catch return null;
    switch (comptime builtin.cpu.arch) {
        .arm, .armeb, .thumb, .thumbeb => {
            const Statfs64 = extern struct {
                f_type: u32,
                f_bsize: u32,
                f_blocks: u64 align(4),
                f_bfree: u64 align(4),
                f_bavail: u64 align(4),
                f_files: u64 align(4),
                f_ffree: u64 align(4),
                f_fsid: [2]i32,
                f_namelen: u32,
                f_frsize: u32,
                f_flags: u32,
                f_spare: [4]u32,
            };
            var s: Statfs64 = undefined;
            const rc = linux.syscall3(.statfs64, @intFromPtr(&path_z), @sizeOf(Statfs64), @intFromPtr(&s));
            if (linux.errno(rc) != .SUCCESS) return null;
            return s.f_bavail *| s.f_bsize;
        },
        else => {
            const Statfs = extern struct {
                f_type: i64,
                f_bsize: i64,
                f_blocks: u64,
                f_bfree: u64,
                f_bavail: u64,
                f_files: u64,
                f_ffree: u64,
                f_fsid: [2]i32,
                f_namelen: i64,
                f_frsize: i64,
                f_flags: i64,
                f_spare: [4]i64,
            };
            var s: Statfs = undefined;
            const rc = linux.syscall2(.statfs, @intFromPtr(&path_z), @intFromPtr(&s));
            if (linux.errno(rc) != .SUCCESS) return null;
            return s.f_bavail *| @as(u64, @intCast(@max(0, s.f_bsize)));
        },
    }
}

fn mkdirQuiet(path: []const u8) void {
    const z = std.posix.toPosixPath(path) catch return;
    _ = linux.mkdirat(linux.AT.FDCWD, &z, 0o755); // EEXIST et al. ignored
}

fn ensureDirs(dir: []const u8) void {
    // One level of parent creation covers /data/.astro/staging (its own
    // parent /data is a mount, guaranteed by the data-mount dependency).
    if (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| {
        if (i > 0) mkdirQuiet(dir[0..i]);
    }
    mkdirQuiet(dir);
}

// ---- the manager ------------------------------------------------------------

pub const HistoryOutcome = enum { installing, succeeded, failed, refused };

const HistoryEntry = struct {
    operation: []u8, // "" for refused requests (no operation was created)
    version: []u8, // "" when unknown (URL installs)
    source: []u8, // "url" | "upload" | "path" | "reattach"
    forced: bool,
    outcome: HistoryOutcome,
};

/// History snapshot row for GET /update/status (all strings, so the JSON
/// shape is explicit rather than depending on enum serialization).
pub const HistoryView = struct {
    operation: []const u8,
    version: []const u8,
    source: []const u8,
    forced: bool,
    outcome: []const u8,
};

const Current = struct { id: []u8, staged: ?[]u8 };

pub const Manager = struct {
    gpa: std.mem.Allocator,
    /// null only in unit tests (no bus available under `zig build test`).
    client: ?rauc.Client,
    registry: *ops.Registry,
    events: *events_mod.EventBus,
    /// The running release (system.zig's ASTRO_RELEASE) the AD-021 gate
    /// compares against; owned copy.
    running_release: []u8,
    staging_dir: []const u8 = default_staging_dir,

    /// Serializes install admission (HTTP threads only; held across the
    /// InstallBundle call — never taken on the bus thread).
    install_mu: sync.Mutex = .{},
    /// LEAF lock: current op / staged path / history. Taken from bus-
    /// thread callbacks; never hold it around a bus call.
    op_mu: sync.Mutex = .{},
    current_op: ?[]u8 = null,
    staged_path: ?[]u8 = null,
    history: std.ArrayList(HistoryEntry) = .empty,

    upload_seq: std.atomic.Value(u32) = .init(0),
    progress_match: ?*bus_mod.Match = null,
    completed_match: ?*bus_mod.Match = null,

    /// Production constructor: connects the RAUC client on `bus`, installs
    /// the daemon-lifetime signal watches and re-attaches to an install
    /// that survived an astrod restart (docs/06 §7).
    pub fn init(
        gpa: std.mem.Allocator,
        bus: *bus_mod.Bus,
        registry: *ops.Registry,
        events: *events_mod.EventBus,
        running_release: []const u8,
    ) error{OutOfMemory}!*Manager {
        const self = try initDetached(gpa, registry, events, running_release);
        errdefer self.deinit();
        self.client = rauc.Client.init(bus);
        self.progress_match = self.client.?.watchProgress(onPropertiesChanged, self) catch |err| blk: {
            std.log.warn("update: progress watch failed ({t}); install progress will not stream", .{err});
            break :blk null;
        };
        self.completed_match = self.client.?.watchCompleted(onCompleted, self) catch |err| blk: {
            std.log.warn("update: completion watch failed ({t})", .{err});
            break :blk null;
        };
        self.attachInFlight();
        return self;
    }

    /// Bus-less constructor for unit tests (client == null: every rauc
    /// path answers 503 through the handlers).
    pub fn initDetached(
        gpa: std.mem.Allocator,
        registry: *ops.Registry,
        events: *events_mod.EventBus,
        running_release: []const u8,
    ) error{OutOfMemory}!*Manager {
        const self = try gpa.create(Manager);
        errdefer gpa.destroy(self);
        const release = try gpa.dupe(u8, running_release);
        self.* = .{
            .gpa = gpa,
            .client = null,
            .registry = registry,
            .events = events,
            .running_release = release,
        };
        return self;
    }

    pub fn deinit(self: *Manager) void {
        // Match.cancel must not run inside a signal callback; deinit is
        // main-thread shutdown, which is fine.
        if (self.progress_match) |m| m.cancel();
        if (self.completed_match) |m| m.cancel();
        if (self.current_op) |id| self.gpa.free(id);
        if (self.staged_path) |p| self.gpa.free(p);
        for (self.history.items) |*h| self.freeHistory(h);
        self.history.deinit(self.gpa);
        self.gpa.free(self.running_release);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    fn freeHistory(self: *Manager, h: *HistoryEntry) void {
        self.gpa.free(h.operation);
        self.gpa.free(h.version);
        self.gpa.free(h.source);
    }

    /// Restart re-attach (docs/06 §7): a non-idle RAUC Operation right
    /// after daemon start means an install RAUC kept running while astrod
    /// was away. Register a NEW operation for it (ids are per-run) and
    /// resume progress tracking through the already-installed watches.
    pub fn attachInFlight(self: *Manager) void {
        var client = self.client orelse return;
        const op = client.operation(self.gpa) catch return;
        defer self.gpa.free(op);
        if (std.mem.eql(u8, op, "idle")) return;

        const id = self.registry.create(.update_install) catch return;
        var pct: u8 = 0;
        if (client.progress(self.gpa)) |p| {
            pct = clampPct(p.percentage);
            self.registry.update(id, .running, pct, p.message);
            self.gpa.free(@constCast(p.message));
        } else |_| {
            self.registry.update(id, .running, 0, "re-attached to in-flight RAUC install");
        }
        self.setCurrent(id, null);
        self.recordHistory(id, "", "reattach", false, .installing);
        self.publishEvent("update.started", .{
            .operation = id,
            .source = "reattach",
            .version = @as(?[]const u8, null),
            .force = false,
        });
    }

    // -- current-op bookkeeping (op_mu) --

    fn setCurrent(self: *Manager, id: []const u8, staged: ?[]const u8) void {
        const id_copy = self.gpa.dupe(u8, id) catch return; // tracking degrades on OOM
        const staged_copy = if (staged) |s| self.gpa.dupe(u8, s) catch null else null;
        self.op_mu.lock();
        defer self.op_mu.unlock();
        if (self.current_op) |old| self.gpa.free(old);
        if (self.staged_path) |old| self.gpa.free(old);
        self.current_op = id_copy;
        self.staged_path = staged_copy;
    }

    fn clearCurrent(self: *Manager) void {
        if (self.takeCurrent()) |cur| {
            self.gpa.free(cur.id);
            if (cur.staged) |p| self.gpa.free(p);
        }
    }

    fn takeCurrent(self: *Manager) ?Current {
        self.op_mu.lock();
        defer self.op_mu.unlock();
        const id = self.current_op orelse return null;
        self.current_op = null;
        const staged = self.staged_path;
        self.staged_path = null;
        return .{ .id = id, .staged = staged };
    }

    const max_id_len = 32;

    /// Copy the in-flight operation id into `buf` (null when idle).
    fn currentOp(self: *Manager, buf: *[max_id_len]u8) ?[]const u8 {
        self.op_mu.lock();
        defer self.op_mu.unlock();
        const id = self.current_op orelse return null;
        if (id.len > buf.len) return null;
        @memcpy(buf[0..id.len], id);
        return buf[0..id.len];
    }

    fn hasCurrent(self: *Manager) bool {
        self.op_mu.lock();
        defer self.op_mu.unlock();
        return self.current_op != null;
    }

    // -- history (op_mu; AD-021: forced installs are surfaced here) --

    fn recordHistory(self: *Manager, op_id: []const u8, ver: []const u8, source: []const u8, forced: bool, outcome: HistoryOutcome) void {
        const op_copy = self.gpa.dupe(u8, op_id) catch return;
        const ver_copy = self.gpa.dupe(u8, ver) catch {
            self.gpa.free(op_copy);
            return;
        };
        const src_copy = self.gpa.dupe(u8, source) catch {
            self.gpa.free(op_copy);
            self.gpa.free(ver_copy);
            return;
        };
        self.op_mu.lock();
        defer self.op_mu.unlock();
        if (self.history.items.len >= max_history) {
            var evicted = self.history.orderedRemove(0);
            self.freeHistory(&evicted);
        }
        self.history.append(self.gpa, .{
            .operation = op_copy,
            .version = ver_copy,
            .source = src_copy,
            .forced = forced,
            .outcome = outcome,
        }) catch {
            self.gpa.free(op_copy);
            self.gpa.free(ver_copy);
            self.gpa.free(src_copy);
        };
    }

    fn setHistoryOutcome(self: *Manager, op_id: []const u8, outcome: HistoryOutcome) void {
        self.op_mu.lock();
        defer self.op_mu.unlock();
        var i = self.history.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.history.items[i].operation, op_id)) {
                self.history.items[i].outcome = outcome;
                return;
            }
        }
    }

    /// Newest-first history rows copied into `allocator` (request arena).
    fn historySnapshot(self: *Manager, allocator: std.mem.Allocator) error{OutOfMemory}![]HistoryView {
        self.op_mu.lock();
        defer self.op_mu.unlock();
        const out = try allocator.alloc(HistoryView, self.history.items.len);
        for (out, 0..) |*row, i| {
            const h = self.history.items[self.history.items.len - 1 - i];
            row.* = .{
                .operation = try allocator.dupe(u8, h.operation),
                .version = try allocator.dupe(u8, h.version),
                .source = try allocator.dupe(u8, h.source),
                .forced = h.forced,
                .outcome = @tagName(h.outcome),
            };
        }
        return out;
    }

    // -- staging --

    pub const StageError = error{ OutOfMemory, InsufficientStorage, StagingFailed };

    /// Write an uploaded body to <staging_dir>/upload-<n>.raucb after a
    /// free-space check. Path allocated from `allocator` (request arena).
    fn stageBody(self: *Manager, allocator: std.mem.Allocator, body: []const u8) StageError![:0]const u8 {
        ensureDirs(self.staging_dir);
        if (freeBytes(self.staging_dir)) |free| {
            if (free < @as(u64, body.len) + staging_margin_bytes) return error.InsufficientStorage;
        }
        const path_z = try self.nextStagingPath(allocator);
        fsutil.writeFileSync(path_z, body) catch return error.StagingFailed;
        return path_z;
    }

    /// Streaming variant for large uploads (the HTTP layer diverts
    /// application/octet-stream bodies here instead of buffering them):
    /// free-space check against the declared length, then prefix +
    /// reader-driven copy into the staged file. `reader` needs
    /// `read([]u8) !usize` (an fd wrapper in main.zig, a slice reader in
    /// tests). A partial file is unlinked on failure.
    pub fn stageStream(self: *Manager, allocator: std.mem.Allocator, prefix: []const u8, reader: anytype, total_len: u64) StageError![:0]const u8 {
        ensureDirs(self.staging_dir);
        if (freeBytes(self.staging_dir)) |free| {
            if (free < total_len + staging_margin_bytes) return error.InsufficientStorage;
        }
        const path_z = try self.nextStagingPath(allocator);
        fsutil.writeStreamSync(path_z, prefix, reader, total_len) catch {
            fsutil.unlink(path_z) catch {};
            return error.StagingFailed;
        };
        return path_z;
    }

    fn nextStagingPath(self: *Manager, allocator: std.mem.Allocator) error{OutOfMemory}![:0]const u8 {
        const n = self.upload_seq.fetchAdd(1, .monotonic) + 1;
        const path = std.fmt.allocPrint(allocator, "{s}/upload-{d}.raucb", .{ self.staging_dir, n }) catch
            return error.OutOfMemory;
        defer allocator.free(path);
        return allocator.dupeZ(u8, path) catch error.OutOfMemory;
    }

    // -- events --

    fn publishEvent(self: *Manager, event_type: []const u8, payload_value: anytype) void {
        const payload = std.json.Stringify.valueAlloc(self.gpa, payload_value, .{}) catch return;
        defer self.gpa.free(payload);
        _ = self.events.publish(event_type, payload) catch 0;
    }

    fn busErrorName(self: *Manager) []const u8 {
        var client = self.client orelse return "";
        return client.lastDbusError();
    }
};

// ---- bus-thread signal callbacks --------------------------------------------
// Contract (bus.zig): they run on the bus thread with the bus mutex HELD.
// Quick work only; ops.Registry / EventBus / op_mu are leaf locks and safe;
// calling back into the Bus is forbidden.

fn onPropertiesChanged(ctx: ?*anyopaque, msg: *bus_mod.Message) void {
    const self: *Manager = @ptrCast(@alignCast(ctx.?));
    const change = (parseProgressChange(msg) catch return) orelse return;
    var idbuf: [Manager.max_id_len]u8 = undefined;
    const id = self.currentOp(&idbuf) orelse return;
    self.registry.update(id, .running, clampPct(change.percentage), change.message);
    self.publishEvent("update.progress", .{
        .operation = id,
        .percentage = change.percentage,
        .message = change.message,
        .depth = change.depth,
    });
}

fn onCompleted(ctx: ?*anyopaque, msg: *bus_mod.Message) void {
    const self: *Manager = @ptrCast(@alignCast(ctx.?));
    const result = msg.readI32() catch return;
    const cur = self.takeCurrent() orelse return; // not ours (or already handled)
    defer {
        self.gpa.free(cur.id);
        if (cur.staged) |p| self.gpa.free(p);
    }

    if (result == 0) {
        self.registry.succeed(cur.id, "installed; new slot marked primary — POST /api/v1/update/apply to reboot into it");
        self.setHistoryOutcome(cur.id, .succeeded);
    } else {
        var buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "RAUC install failed (result {d}); see GET /api/v1/update/status last_error", .{result}) catch "RAUC install failed";
        self.registry.fail(cur.id, detail);
        self.setHistoryOutcome(cur.id, .failed);
    }
    // A consumed staged upload is garbage either way (a failed bundle is
    // re-uploaded, not retried in place).
    if (cur.staged) |p| fsutil.unlink(p) catch {};

    self.publishEvent("update.completed", .{
        .operation = cur.id,
        .result = @as([]const u8, if (result == 0) "succeeded" else "failed"),
    });
}

// ---- problem helpers --------------------------------------------------------

fn unavailable(ctx: *router.Context, detail: []const u8) router.Response {
    return router.problemResponse(ctx, .{
        .type = "urn:astro:problem:rauc-unavailable",
        .title = "Service Unavailable",
        .status = 503,
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

fn conflict(ctx: *router.Context, problem_type: []const u8, detail: []const u8) router.Response {
    return router.problemResponse(ctx, .{
        .type = problem_type,
        .title = "Conflict",
        .status = 409,
        .detail = detail,
    });
}

/// Map a rauc client failure to a problem: transport loss is a 503
/// (retryable), a rejected call is a 502 with the D-Bus error name; a
/// reply OUR parser could not walk is a 502 WITHOUT the last D-Bus error
/// (that would be stale — the call itself succeeded on the bus). OOM
/// propagates (dispatch turns it into the 500 problem).
fn raucFailure(ctx: *router.Context, mgr: *Manager, err: rauc.Error) anyerror!router.Response {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoBusSocket, error.ConnectFailed, error.Disconnected => unavailable(ctx, "the RAUC D-Bus connection is down"),
        error.RaucFailed, error.CallFailed => router.problemResponse(ctx, .{
            .type = "urn:astro:problem:rauc-error",
            .title = "Bad Gateway",
            .status = 502,
            .detail = std.fmt.allocPrint(ctx.allocator, "RAUC call failed ({t}); D-Bus error: {s}", .{
                err, mgr.busErrorName(),
            }) catch null,
        }),
        error.InvalidReply, error.InvalidArgs => router.problemResponse(ctx, .{
            .type = "urn:astro:problem:rauc-error",
            .title = "Bad Gateway",
            .status = 502,
            .detail = std.fmt.allocPrint(ctx.allocator, "RAUC reply did not match the expected shape ({t}); daemon/client version drift?", .{err}) catch null,
        }),
    };
}

fn managerOr503(ctx: *router.Context) ?*Manager {
    _ = ctx;
    return manager;
}

// ---- handlers (wired into router.zig by the shared-file followup) -----------

/// GET /api/v1/update/status — docs/06 §5.3: slots, booted slot, primary,
/// installer state, AD-021 context (running release, history incl. forced
/// installs), pending flag for the apply flow.
pub fn getUpdateStatus(ctx: *router.Context) anyerror!router.Response {
    const mgr = managerOr503(ctx) orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
    var client = mgr.client orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
    const st = client.status(ctx.allocator) catch |err| return raucFailure(ctx, mgr, err);

    var idbuf: [Manager.max_id_len]u8 = undefined;
    const doc = .{
        .boot_slot = st.boot_slot,
        .primary = st.primary,
        .operation = st.operation,
        .last_error = st.last_error,
        .compatible = st.compatible,
        .running_release = @as([]const u8, mgr.running_release),
        .pending = hasPendingSlot(st),
        .current_operation = mgr.currentOp(&idbuf),
        .slots = st.slots,
        .history = try mgr.historySnapshot(ctx.allocator),
    };
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator, doc, .{}) };
}

/// POST /api/v1/update — {"url": ...} JSON (http(s) URL or absolute local
/// path) or the raw bundle bytes (staged to /data/.astro/staging). 202 +
/// operation on acceptance.
pub fn postUpdate(ctx: *router.Context) anyerror!router.Response {
    // AD-021 force can ride the query string (?force=true): the only
    // channel available to the octet-stream form, OR-ed with the JSON
    // body field on the command form (spec: parameters of POST /update).
    const query_force = queryFlag(ctx.request.query, "force");

    // Large octet-stream upload, already staged by the HTTP layer
    // (docs/06 §7: bundle bodies are streamed to /data, never buffered).
    if (ctx.request.staged_upload) |staged| {
        const mgr = managerOr503(ctx) orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
        return installPath(ctx, mgr, staged, query_force, staged, "upload");
    }

    const body = ctx.request.body;
    const first = firstNonWhitespace(body) orelse
        return badRequest(ctx, "empty body: send {\"url\": \"...\"} or the raw bundle bytes");

    if (body[first] == '{') {
        // JSON command form. Validation runs before the subsystem check so
        // a malformed request is a 400 even while RAUC is unreachable.
        const req = parseInstallRequest(ctx.allocator, body) orelse
            return badRequest(ctx, "body must be {\"url\": \"...\", \"force\": bool} (unknown fields rejected)");
        const url = req.url orelse return badRequest(ctx, "missing \"url\"");
        if (req.apply != null)
            return badRequest(ctx, "\"apply\" is reserved (docs/05 §5.1) and not supported in v1; poll the operation and POST /update/apply");
        const is_path = url.len > 0 and url[0] == '/';
        if (!is_path and !std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://"))
            return badRequest(ctx, "\"url\" must be an http(s) URL or an absolute local path");
        const force = req.force or query_force;

        const mgr = managerOr503(ctx) orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
        const url_z = try ctx.allocator.dupeZ(u8, url);
        if (is_path) return installPath(ctx, mgr, url_z, force, null, "path");
        // AD-021 v1 limitation: no pre-install metadata for streamed URL
        // installs — the version gate cannot run (see module doc).
        return startInstall(ctx, mgr, .{ .url = url_z }, "", force, null, "url");
    }

    // Small raw bundle upload that arrived through the buffered body path
    // (no octet-stream content type — e.g. curl --data-binary without
    // headers; capped by the HTTP layer's body limit).
    const mgr = managerOr503(ctx) orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
    if (mgr.client == null) return unavailable(ctx, "update subsystem is not connected to D-Bus");
    const staged = mgr.stageBody(ctx.allocator, body) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InsufficientStorage => router.problemResponse(ctx, .{
            .type = "urn:astro:problem:insufficient-storage",
            .title = "Insufficient Storage",
            .status = 507,
            .detail = "not enough free space on /data to stage the bundle",
        }),
        error.StagingFailed => router.problemResponse(ctx, .{
            .type = "urn:astro:problem:staging-failed",
            .title = "Internal Server Error",
            .status = 500,
            .detail = "could not write the bundle to the staging directory",
        }),
    };
    // Raw uploads carry force via ?force=true only (no JSON body); a
    // downgrade answer keeps the staged file and names it so the client
    // can also force via the JSON path form without re-uploading.
    return installPath(ctx, mgr, staged, query_force, staged, "upload");
}

/// Inspect + AD-021 gate + install for a local bundle path.
fn installPath(
    ctx: *router.Context,
    mgr: *Manager,
    path: [:0]const u8,
    force: bool,
    staged: ?[:0]const u8,
    source_kind: []const u8,
) anyerror!router.Response {
    var client = mgr.client orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
    const info = client.inspect(ctx.allocator, path) catch |err| switch (err) {
        error.RaucFailed => {
            // Signature-first: an unverifiable/corrupt bundle is the
            // client's fault, not a gateway error.
            if (staged) |p| fsutil.unlink(p) catch {};
            return router.problemResponse(ctx, .{
                .type = "urn:astro:problem:invalid-bundle",
                .title = "Bad Request",
                .status = 400,
                .detail = std.fmt.allocPrint(ctx.allocator, "bundle verification/inspection failed; D-Bus error: {s}", .{mgr.busErrorName()}) catch null,
            });
        },
        else => return raucFailure(ctx, mgr, err),
    };

    switch (versionGate(info.version, mgr.running_release, force)) {
        .refuse => {
            mgr.recordHistory("", info.version, source_kind, false, .refused);
            return conflict(ctx, "urn:astro:problem:update-downgrade-refused", try std.fmt.allocPrint(
                ctx.allocator,
                "AD-021: bundle version \"{s}\" is not newer than running release \"{s}\"; bundle kept at {s} — re-POST {{\"url\": \"{s}\", \"force\": true}} to override",
                .{ info.version, mgr.running_release, path, path },
            ));
        },
        .forced => std.log.warn("update: AD-021 gate FORCED: installing \"{s}\" over running \"{s}\"", .{ info.version, mgr.running_release }),
        .allow => {},
    }
    return startInstall(ctx, mgr, .{ .path = path }, info.version, force, staged, source_kind);
}

/// Admission + InstallBundle + operation/history/event bookkeeping.
fn startInstall(
    ctx: *router.Context,
    mgr: *Manager,
    source: rauc.Source,
    bundle_version: []const u8,
    forced: bool,
    staged: ?[:0]const u8,
    source_kind: []const u8,
) anyerror!router.Response {
    var client = mgr.client orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");

    mgr.install_mu.lock();
    defer mgr.install_mu.unlock();
    if (mgr.hasCurrent())
        return conflict(ctx, "urn:astro:problem:update-in-progress", "an install operation is already in flight; poll /api/v1/operations");

    const id = try mgr.registry.create(.update_install);
    mgr.registry.update(id, .running, 0, "InstallBundle dispatched to RAUC");
    // Current-op is set BEFORE the call so the first progress signal (bus
    // thread) cannot race past an unset id; rolled back on dispatch failure.
    mgr.setCurrent(id, staged);

    client.install(source, .{ .force = forced }) catch |err| {
        mgr.clearCurrent();
        const detail = std.fmt.allocPrint(ctx.allocator, "InstallBundle dispatch failed ({t}); D-Bus error: {s}", .{ err, mgr.busErrorName() }) catch "InstallBundle dispatch failed";
        mgr.registry.fail(id, detail);
        if (staged) |p| fsutil.unlink(p) catch {};
        return raucFailure(ctx, mgr, err);
    };

    mgr.recordHistory(id, bundle_version, source_kind, forced, .installing);
    mgr.publishEvent("update.started", .{
        .operation = id,
        .source = source_kind,
        .version = @as(?[]const u8, if (bundle_version.len > 0) bundle_version else null),
        .force = forced,
    });

    const op_url = try std.fmt.allocPrint(ctx.allocator, "/api/v1/operations/{s}", .{id});
    return .{
        .status = 202,
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .operation = op_url }, .{}),
    };
}

/// POST /api/v1/update/apply — reboot into the pending primary slot; 409
/// when nothing is pending or an install is still running (docs/06 §5.3
/// "no-op error if none pending"). Reboot rides the existing deferred
/// dinit SHUTDOWN path (response first, then teardown).
pub fn postUpdateApply(ctx: *router.Context) anyerror!router.Response {
    const mgr = managerOr503(ctx) orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
    var client = mgr.client orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
    const st = client.status(ctx.allocator) catch |err| return raucFailure(ctx, mgr, err);

    if (!std.mem.eql(u8, st.operation, "idle"))
        return conflict(ctx, "urn:astro:problem:update-in-progress", "RAUC is busy; wait for the install operation to finish");
    if (!hasPendingSlot(st))
        return conflict(ctx, "urn:astro:problem:no-pending-update", "no newly installed slot is pending activation; POST /api/v1/update first");

    if (probeDinit(ctx)) |resp| return resp;
    ctx.deferred = .{ .shutdown = .reboot };
    return .{ .status = 202, .body = "{\"operation\":null}" };
}

/// POST /api/v1/update/rollback — docs/05 §5.1: make the other slot
/// primary, mark the booted slot bad, reboot. Activation runs FIRST so a
/// partial failure leaves the system bootable into the rollback target
/// rather than marked-bad with no alternative armed.
pub fn postUpdateRollback(ctx: *router.Context) anyerror!router.Response {
    const mgr = managerOr503(ctx) orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
    var client = mgr.client orelse return unavailable(ctx, "update subsystem is not connected to D-Bus");
    const st = client.status(ctx.allocator) catch |err| return raucFailure(ctx, mgr, err);

    if (!std.mem.eql(u8, st.operation, "idle"))
        return conflict(ctx, "urn:astro:problem:update-in-progress", "RAUC is busy; wait for the install operation to finish");
    if (!isRollbackable(st))
        return conflict(ctx, "urn:astro:problem:no-rollback-target", "the other slot has never held a release; nothing to roll back to");

    client.activateOther() catch |err| return raucFailure(ctx, mgr, err);
    client.markBad() catch |err| {
        // The other slot is already primary: still not rebooting — the
        // operator must know the booted slot was NOT marked bad.
        return raucFailure(ctx, mgr, err);
    };

    if (probeDinit(ctx)) |resp| return resp;
    mgr.publishEvent("update.rollback", .{ .boot_slot = st.boot_slot });
    ctx.deferred = .{ .shutdown = .reboot };
    return .{ .status = 202, .body = "{\"operation\":null}" };
}

/// Same probe-then-defer discipline as router.powerAction: confirm the
/// dinit control socket answers before promising a reboot; the SHUTDOWN
/// itself runs on the connection thread after the response is written.
fn probeDinit(ctx: *router.Context) ?router.Response {
    var probe = dinit.Client.connect(dinit.default_socket_path) catch |err| return router.problemResponse(ctx, switch (err) {
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
    return null;
}

fn firstNonWhitespace(s: []const u8) ?usize {
    for (s, 0..) |ch, i| {
        switch (ch) {
            ' ', '\t', '\r', '\n' => {},
            else => return i,
        }
    }
    return null;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "AD-021 versionGate: allowed, refused, forced" {
    // Upgrades and re-installs pass.
    try testing.expectEqual(GateDecision.allow, versionGate("0.3.0", "0.2.0", false));
    try testing.expectEqual(GateDecision.allow, versionGate("0.2.0", "0.2.0", false));
    try testing.expectEqual(GateDecision.allow, versionGate("0.2.0", "0.2.0-rc1", false));
    // Downgrades refuse without force, pass with it.
    try testing.expectEqual(GateDecision.refuse, versionGate("0.1.0", "0.2.0", false));
    try testing.expectEqual(GateDecision.forced, versionGate("0.1.0", "0.2.0", true));
    try testing.expectEqual(GateDecision.refuse, versionGate("0.2.0-rc1", "0.2.0", false));
    // Unknown bundle version is conservative: refuse unless forced.
    try testing.expectEqual(GateDecision.refuse, versionGate("", "0.2.0", false));
    try testing.expectEqual(GateDecision.forced, versionGate("", "0.2.0", true));
}

test "hasPendingSlot compares primary against the booted slot's name" {
    var slots = [_]rauc.SlotStatus{
        .{ .name = "system.0", .state = "booted" },
        .{ .name = "system.1", .state = "inactive", .bundle_version = "0.2.0" },
    };
    var st: rauc.Status = .{
        .boot_slot = "A",
        .primary = "system.1",
        .operation = "idle",
        .last_error = "",
        .compatible = "astro-qemu-x86_64",
        .slots = &slots,
    };
    try testing.expect(hasPendingSlot(st));
    st.primary = "system.0"; // primary == booted: nothing pending
    try testing.expect(!hasPendingSlot(st));
    st.primary = null; // bootloader gave no answer
    try testing.expect(!hasPendingSlot(st));
}

test "isRollbackable requires a non-booted slot that has held a release" {
    var ok = [_]rauc.SlotStatus{
        .{ .name = "system.0", .state = "booted", .bundle_version = "0.2.0" },
        .{ .name = "system.1", .state = "inactive", .bundle_version = "0.1.0" },
    };
    var fresh = [_]rauc.SlotStatus{
        .{ .name = "system.0", .state = "booted", .bundle_version = "0.2.0" },
        .{ .name = "system.1", .state = "inactive" }, // factory-fresh
    };
    const base: rauc.Status = .{
        .boot_slot = "A",
        .primary = null,
        .operation = "idle",
        .last_error = "",
        .compatible = "",
        .slots = &ok,
    };
    try testing.expect(isRollbackable(base));
    var no_target = base;
    no_target.slots = &fresh;
    try testing.expect(!isRollbackable(no_target));
}

test "parseInstallRequest: valid forms, unknown fields rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const full = parseInstallRequest(a, "{\"url\": \"https://x/y.raucb\", \"force\": true}").?;
    try testing.expectEqualStrings("https://x/y.raucb", full.url.?);
    try testing.expect(full.force);

    const bare = parseInstallRequest(a, "{\"url\": \"/data/.astro/staging/upload-1.raucb\"}").?;
    try testing.expect(!bare.force);

    const missing = parseInstallRequest(a, "{}").?;
    try testing.expect(missing.url == null);

    // docs/06 §4: unknown request fields are rejected to surface typos.
    try testing.expect(parseInstallRequest(a, "{\"utl\": \"x\"}") == null);
    try testing.expect(parseInstallRequest(a, "not json") == null);
}

test "parseProgressChange reads the (isi) Progress variant per the XML" {
    // PropertiesChanged body: s interface, a{sv} changed, as invalidated
    // (the trailing "as" stays unread).
    var msg: rauc.FakeMessage = .{
        .script = &.{
            .{ .str = "de.pengutronix.rauc.Installer" },
            .{ .enter = .{ .kind = 'a', .contents = "{sv}", .result = true } },
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "Operation" }, // changed alongside Progress -> skipped
            .{ .skipped = "v" },
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "Progress" },
            .{ .enter = .{ .kind = 'v', .contents = "(isi)", .result = true } },
            .{ .enter = .{ .kind = 'r', .contents = "isi", .result = true } },
            .{ .int32 = 55 },
            .{ .str = "Copying image to rootfs.1" },
            .{ .int32 = 2 },
            .exit,
            .exit,
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = false } },
            .exit,
        },
    };
    const change = (try parseProgressChange(&msg)).?;
    try testing.expect(msg.exhausted());
    try testing.expectEqual(@as(i32, 55), change.percentage);
    try testing.expectEqualStrings("Copying image to rootfs.1", change.message);
    try testing.expectEqual(@as(i32, 2), change.depth);
}

test "parseProgressChange ignores other interfaces" {
    var msg: rauc.FakeMessage = .{ .script = &.{
        .{ .str = "org.freedesktop.systemd1.Manager" },
    } };
    try testing.expect((try parseProgressChange(&msg)) == null);
}

test "freeBytes reports space for a real filesystem" {
    const free = freeBytes("/tmp") orelse return error.TestUnexpectedResult;
    try testing.expect(free > 0);
    try testing.expect(freeBytes("/nonexistent-astro-test") == null);
}

const TestRig = struct {
    registry: ops.Registry,
    events: events_mod.EventBus,
    mgr: *Manager,

    fn init(staging: ?[]const u8) !*TestRig {
        const self = try testing.allocator.create(TestRig);
        self.registry = ops.Registry.init(testing.allocator);
        self.events = events_mod.EventBus.init(testing.allocator);
        self.mgr = try Manager.initDetached(testing.allocator, &self.registry, &self.events, "0.2.0");
        if (staging) |dir| self.mgr.staging_dir = dir;
        return self;
    }

    fn deinit(self: *TestRig) void {
        self.mgr.deinit();
        self.events.deinit();
        self.registry.deinit();
        testing.allocator.destroy(self);
    }
};

test "stageBody writes sequenced upload files and round-trips the bytes" {
    var dirbuf: [128]u8 = undefined;
    const dir = fsutil.testTmpPath(&dirbuf, "staging");
    var rig = try TestRig.init(dir);
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const p1 = try rig.mgr.stageBody(arena.allocator(), "bundle-bytes-1");
    defer fsutil.unlink(p1) catch {};
    try testing.expect(std.mem.endsWith(u8, p1, "/upload-1.raucb"));
    const back = try fsutil.readFileAlloc(arena.allocator(), p1, 1024);
    try testing.expectEqualStrings("bundle-bytes-1", back);

    const p2 = try rig.mgr.stageBody(arena.allocator(), "bundle-bytes-2");
    defer fsutil.unlink(p2) catch {};
    try testing.expect(std.mem.endsWith(u8, p2, "/upload-2.raucb"));
}

test "queryFlag parses the documented ?force forms" {
    try testing.expect(queryFlag("force=true", "force"));
    try testing.expect(queryFlag("force=1", "force"));
    try testing.expect(queryFlag("force", "force"));
    try testing.expect(queryFlag("a=b&force=true", "force"));
    try testing.expect(!queryFlag("force=false", "force"));
    try testing.expect(!queryFlag("force=yes", "force"));
    try testing.expect(!queryFlag("", "force"));
    try testing.expect(!queryFlag("forced=true", "force"));
    try testing.expect(!queryFlag("a=force", "force"));
}

/// Slice-backed reader for stageStream tests (the fd wrapper's shape).
const SliceReader = struct {
    rest: []const u8,
    /// Bytes per read, to prove short reads are handled.
    chunk: usize,

    pub fn read(self: *SliceReader, buf: []u8) !usize {
        const n = @min(@min(self.chunk, buf.len), self.rest.len);
        @memcpy(buf[0..n], self.rest[0..n]);
        self.rest = self.rest[n..];
        return n;
    }
};

test "stageStream: prefix + chunked reader round-trips; short body fails and cleans up" {
    var dirbuf: [128]u8 = undefined;
    const dir = fsutil.testTmpPath(&dirbuf, "staging-stream");
    var rig = try TestRig.init(dir);
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const payload = "0123456789abcdef";
    var reader: SliceReader = .{ .rest = payload[4..], .chunk = 3 };
    const p = try rig.mgr.stageStream(arena.allocator(), payload[0..4], &reader, payload.len);
    defer fsutil.unlink(p) catch {};
    try testing.expect(std.mem.endsWith(u8, p, "/upload-1.raucb"));
    const back = try fsutil.readFileAlloc(arena.allocator(), p, 1024);
    try testing.expectEqualStrings(payload, back);

    // Peer closes mid-body: StagingFailed, and the partial file is gone.
    var short: SliceReader = .{ .rest = "abc", .chunk = 2 };
    try testing.expectError(error.StagingFailed, rig.mgr.stageStream(arena.allocator(), "", &short, 100));
    var namebuf: [160]u8 = undefined;
    const partial = try std.fmt.bufPrint(&namebuf, "{s}/upload-2.raucb", .{dir});
    try testing.expect(!fsutil.exists(partial));
}

fn testCtx(allocator: std.mem.Allocator, st: *store_mod.Store, method: router.Method, path: []const u8, body: []const u8) router.Context {
    return .{ .allocator = allocator, .store = st, .request = .{ .method = method, .path = path, .body = body } };
}

test "handlers answer 503 rauc-unavailable while no manager is wired" {
    try testing.expect(manager == null); // tests must not leak a global
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st = try store_mod.Store.load(testing.allocator, "/nonexistent/astro.json");
    defer st.deinit();

    const cases = [_]struct { h: router.Handler, m: router.Method, p: []const u8, b: []const u8 }{
        .{ .h = getUpdateStatus, .m = .GET, .p = "/api/v1/update/status", .b = "" },
        .{ .h = postUpdate, .m = .POST, .p = "/api/v1/update", .b = "{\"url\": \"https://x/y.raucb\"}" },
        .{ .h = postUpdate, .m = .POST, .p = "/api/v1/update", .b = "raw-bundle-bytes" },
        .{ .h = postUpdateApply, .m = .POST, .p = "/api/v1/update/apply", .b = "" },
        .{ .h = postUpdateRollback, .m = .POST, .p = "/api/v1/update/rollback", .b = "" },
    };
    for (cases) |case| {
        var ctx = testCtx(arena.allocator(), &st, case.m, case.p, case.b);
        const resp = try case.h(&ctx);
        try testing.expectEqual(@as(u16, 503), resp.status);
        try testing.expect(std.mem.indexOf(u8, resp.body, "urn:astro:problem:rauc-unavailable") != null);
    }
}

test "POST /update validates the JSON body before touching the subsystem" {
    try testing.expect(manager == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st = try store_mod.Store.load(testing.allocator, "/nonexistent/astro.json");
    defer st.deinit();

    const bad_bodies = [_][]const u8{
        "", // empty
        "   \r\n", // whitespace only
        "{\"utl\": \"x\"}", // typo'd field
        "{}", // missing url
        "{\"url\": \"ftp://host/b.raucb\"}", // unsupported scheme
        "{\"url\": \"relative/path.raucb\"}", // neither absolute path nor http(s)
        "{\"url\": \"https://x\", \"apply\": \"auto\"}", // reserved apply key
    };
    for (bad_bodies) |body| {
        var ctx = testCtx(arena.allocator(), &st, .POST, "/api/v1/update", body);
        const resp = try postUpdate(&ctx);
        try testing.expectEqual(@as(u16, 400), resp.status);
        try testing.expectEqualStrings(problem.content_type, resp.content_type);
    }
}

test "attachInFlight is a no-op without a bus client" {
    var rig = try TestRig.init(null);
    defer rig.deinit();
    rig.mgr.attachInFlight();
    try testing.expect(!rig.mgr.hasCurrent());
    const list = try rig.registry.list(testing.allocator);
    defer ops.freeList(testing.allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "history: bounded ring, forced installs surfaced, outcome updates" {
    var rig = try TestRig.init(null);
    defer rig.deinit();
    const mgr = rig.mgr;

    mgr.recordHistory("op-1", "0.1.0", "upload", true, .installing);
    mgr.setHistoryOutcome("op-1", .succeeded);
    mgr.recordHistory("", "0.0.9", "upload", false, .refused);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try mgr.historySnapshot(arena.allocator());
    try testing.expectEqual(@as(usize, 2), rows.len);
    // Newest first.
    try testing.expectEqualStrings("refused", rows[0].outcome);
    try testing.expectEqualStrings("0.0.9", rows[0].version);
    try testing.expectEqualStrings("succeeded", rows[1].outcome);
    try testing.expect(rows[1].forced);

    // Bound: filling past max_history evicts the oldest.
    var n: usize = 0;
    while (n < max_history + 3) : (n += 1) mgr.recordHistory("op-x", "1.0.0", "url", false, .installing);
    const bounded = try mgr.historySnapshot(arena.allocator());
    try testing.expectEqual(@as(usize, max_history), bounded.len);
}

test "current-op bookkeeping: set, read from a signal-thread buffer, take" {
    var rig = try TestRig.init(null);
    defer rig.deinit();
    const mgr = rig.mgr;

    try testing.expect(!mgr.hasCurrent());
    mgr.setCurrent("op-7", "/tmp/staged.raucb");
    var buf: [Manager.max_id_len]u8 = undefined;
    try testing.expectEqualStrings("op-7", mgr.currentOp(&buf).?);

    const cur = mgr.takeCurrent().?;
    defer {
        testing.allocator.free(cur.id);
        if (cur.staged) |p| testing.allocator.free(p);
    }
    try testing.expectEqualStrings("op-7", cur.id);
    try testing.expectEqualStrings("/tmp/staged.raucb", cur.staged.?);
    try testing.expect(!mgr.hasCurrent());
    try testing.expect(mgr.takeCurrent() == null);
}

test "live RAUC install flow (manual only)" {
    // Requires dbus-daemon + rauc; exercised end-to-end by the AD-020
    // gate (build/test-update-rollback.sh) in the QEMU rig. Compiled so
    // the call surface cannot rot.
    if (true) return error.SkipZigTest;
    var registry = ops.Registry.init(testing.allocator);
    defer registry.deinit();
    var events = events_mod.EventBus.init(testing.allocator);
    defer events.deinit();
    var bus = try bus_mod.Bus.connectSystem(testing.allocator);
    defer bus.deinit();
    try bus.start();
    const mgr = try Manager.init(testing.allocator, bus, &registry, &events, "0.0.0-dev");
    defer mgr.deinit();
    manager = mgr;
    defer manager = null;
}
