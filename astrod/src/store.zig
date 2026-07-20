//! Config store: one versioned JSON document at /data/config/astro.json,
//! atomic writes (tmp + fsync + rename + parent-dir fsync), restorable-
//! from-/data contract (docs/06 §1).
//!
//! Load policy: missing file → defaults without writing (pre-firstboot
//! device; firstboot bakes the initial document, docs/07 §4). A document
//! with schema newer than this daemon is refused outright — writing it
//! back would silently drop fields a newer writer cared about.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const fsutil = @import("fsutil.zig");
const sync = @import("sync.zig");

pub const default_path = "/data/config/astro.json";
pub const schema_version: u32 = 1;

const max_document_len = 1024 * 1024;

pub const LoadError = error{
    /// Document schema is newer than this daemon understands. Downgrade-
    /// with-rewrite would lose data; the caller must surface this and stop.
    SchemaTooNew,
};

/// The persisted document. Unknown fields are tolerated on read (forward
/// compat within a schema); the fields here are the v1 set this phase
/// owns. TODO(fill): network/wifi/wan/update subtrees per docs/06 §5.
pub const Config = struct {
    schema: u32 = schema_version,
    hostname: []const u8 = "astro",
    system: System = .{},
    api: Api = .{},

    pub const System = struct {
        /// Provisioning state machine (docs/07 §4):
        /// factory → provisioning → provisioned.
        provisioning: []const u8 = "factory",
    };

    /// Feature flags baked into the image defaults (docs/03 §6 `[api]`);
    /// defaults here mirror the stock board.toml values so a device with
    /// no document yet behaves like a freshly built image.
    pub const Api = struct {
        wifi: bool = true,
        ap_provisioning: bool = true,
        mdns: bool = true,
        lan_exposure: bool = false, // AD-025: LAN exposure defaults off
    };
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    config: Config,
    // Keeps string fields of `config` alive when they were parsed from disk;
    // null when `config` is all comptime defaults.
    parsed: ?std.json.Parsed(Config),
    /// Connection threads read concurrently; mutations are exclusive.
    /// Getters take the shared lock internally. A mutate-then-persist
    /// sequence wraps itself in beginMutate()/endMutate() and calls
    /// persistLocked() inside (persist() self-locks for standalone use).
    /// String getters return slices into `config`; they stay valid because
    /// the backing memory (`parsed`) is only replaced at load — a future
    /// reload-in-place must copy instead.
    mu: sync.RwLock = .{},

    /// Load the store. A missing file yields defaults (pre-firstboot
    /// device). A file with schema > schema_version is refused (see
    /// LoadError). TODO(fill): corrupt JSON currently also falls back to
    /// defaults — must become "keep last-known-good + surface degraded
    /// health" instead.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Store {
        const raw = fsutil.readFileAlloc(allocator, path, max_document_len) catch {
            return .{ .allocator = allocator, .path = path, .config = .{}, .parsed = null };
        };
        defer allocator.free(raw);

        const parsed = std.json.parseFromSlice(Config, allocator, raw, .{
            .ignore_unknown_fields = true, // forward-compat: newer writers may add fields
            .allocate = .alloc_always, // config strings must outlive `raw`
        }) catch {
            return .{ .allocator = allocator, .path = path, .config = .{}, .parsed = null };
        };
        if (parsed.value.schema > schema_version) {
            parsed.deinit();
            return LoadError.SchemaTooNew;
        }

        var store: Store = .{ .allocator = allocator, .path = path, .config = parsed.value, .parsed = parsed };
        migrate(&store.config);
        return store;
    }

    pub fn deinit(self: *Store) void {
        if (self.parsed) |p| p.deinit();
        self.* = undefined;
    }

    pub fn getSchema(self: *Store) u32 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.schema;
    }

    pub fn getHostname(self: *Store) []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.hostname;
    }

    pub fn getProvisioning(self: *Store) []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.system.provisioning;
    }

    pub fn getLanExposure(self: *Store) bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.api.lan_exposure;
    }

    pub fn getApi(self: *Store) Config.Api {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.api;
    }

    /// Take the exclusive lock for a config mutation + persistLocked()
    /// sequence (PUT/PATCH handlers in stage 2+).
    pub fn beginMutate(self: *Store) void {
        self.mu.lock();
    }

    pub fn endMutate(self: *Store) void {
        self.mu.unlock();
    }

    /// Standalone persist (no surrounding mutation): self-locking.
    pub fn persist(self: *Store) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.persistLocked();
    }

    /// Atomic persist: serialize → <path>.tmp (0640, fsync) → rename →
    /// fsync parent dir. The dir fsync is what makes the *rename* durable
    /// across power loss, not just the bytes. Deployment: firstboot seeds
    /// the document astrod-owned (0600) and chowns /data/config to
    /// astrod:astro-api 0710, so the unprivileged daemon can create the
    /// tmp file and rename; rewrites land 0640 astrod:astrod (the group
    /// is the daemon's primary group — sole member: the daemon).
    /// Caller holds the exclusive lock (beginMutate or persist()).
    pub fn persistLocked(self: *const Store) !void {
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{self.path});

        const doc = try std.json.Stringify.valueAlloc(self.allocator, self.config, .{ .whitespace = .indent_2 });
        defer self.allocator.free(doc);

        try writeFileSyncMode(tmp_path, doc, 0o640);
        try fsutil.rename(tmp_path, self.path);
        try syncParentDir(self.path);
    }
};

/// Forward-migration hook (docs/05 §7). Runs after a successful load with
/// schema <= schema_version. TODO(migration): when schema_version grows
/// past 1, transform older documents field-by-field here and bump
/// config.schema so the next persist() writes the upgraded form.
fn migrate(config: *Config) void {
    std.debug.assert(config.schema <= schema_version);
}

// ---- raw-syscall helpers (same pattern as fsutil, kept local because the
// store needs a tighter file mode and a directory fsync that no other
// module wants) --------------------------------------------------------------

fn check(rc: usize) fsutil.Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOENT => error.FileNotFound,
        else => |e| posix.unexpectedErrno(e),
    };
}

/// Like fsutil.writeFileSync but with an explicit mode: the store document
/// is 0640 (group astro-api readable, world-unreadable — docs/06 §6),
/// while fsutil's default 0644 suits its other callers.
fn writeFileSyncMode(path: []const u8, bytes: []const u8, mode: linux.mode_t) fsutil.Error!void {
    const path_z = posix.toPosixPath(path) catch return error.NameTooLong;
    const fd: posix.fd_t = @intCast(try check(linux.openat(
        linux.AT.FDCWD,
        &path_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        mode,
    )));
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        off += try check(linux.write(fd, bytes[off..].ptr, bytes.len - off));
    }
    _ = try check(linux.fsync(fd));
}

fn syncParentDir(path: []const u8) fsutil.Error!void {
    const dir = std.fs.path.dirname(path) orelse ".";
    const dir_z = posix.toPosixPath(dir) catch return error.NameTooLong;
    const fd: posix.fd_t = @intCast(try check(linux.openat(
        linux.AT.FDCWD,
        &dir_z,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
        0,
    )));
    defer _ = linux.close(fd);
    _ = try check(linux.fsync(fd));
}

// ---- tests -----------------------------------------------------------------

test "load returns defaults when the file is absent" {
    var s = try Store.load(std.testing.allocator, "/nonexistent/astro.json");
    defer s.deinit();
    try std.testing.expectEqual(schema_version, s.getSchema());
    try std.testing.expectEqualStrings("astro", s.getHostname());
    try std.testing.expectEqualStrings("factory", s.getProvisioning());
    try std.testing.expect(!s.getLanExposure());
    try std.testing.expect(s.getApi().wifi);
    try std.testing.expect(s.getApi().ap_provisioning);
    try std.testing.expect(s.getApi().mdns);
}

test "persist writes atomically, fsyncs, and load round-trips all subtrees" {
    const allocator = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "astro.json");
    defer fsutil.unlink(path) catch {};

    var s = try Store.load(allocator, path);
    defer s.deinit();
    s.config.hostname = "unit-test-host";
    s.config.system.provisioning = "provisioned";
    s.config.api.lan_exposure = true;
    s.config.api.mdns = false;
    try s.persist();

    // No .tmp litter after a successful persist.
    var tmp_buf: [140]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    try std.testing.expect(!fsutil.exists(tmp_path));

    var s2 = try Store.load(allocator, path);
    defer s2.deinit();
    try std.testing.expectEqualStrings("unit-test-host", s2.getHostname());
    try std.testing.expectEqual(schema_version, s2.getSchema());
    try std.testing.expectEqualStrings("provisioned", s2.getProvisioning());
    try std.testing.expect(s2.getLanExposure());
    try std.testing.expect(!s2.getApi().mdns);
    try std.testing.expect(s2.getApi().wifi); // untouched flag keeps its default
}

test "load refuses a document with a newer schema" {
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "astro-v2.json");
    defer fsutil.unlink(path) catch {};
    try fsutil.writeFileSync(path,
        \\{"schema": 2, "hostname": "from-the-future"}
    );

    try std.testing.expectError(LoadError.SchemaTooNew, Store.load(std.testing.allocator, path));
}

test "load tolerates unknown fields from newer writers within the schema" {
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "astro-fwd.json");
    defer fsutil.unlink(path) catch {};
    try fsutil.writeFileSync(path,
        \\{"schema": 1, "hostname": "h1",
        \\ "system": {"provisioning": "provisioning", "future_field": true},
        \\ "api": {"lan_exposure": true}, "future_field": 42}
    );

    var s = try Store.load(std.testing.allocator, path);
    defer s.deinit();
    try std.testing.expectEqualStrings("h1", s.getHostname());
    try std.testing.expectEqualStrings("provisioning", s.getProvisioning());
    try std.testing.expect(s.getLanExposure());
}

test "load falls back to defaults on a corrupt document" {
    // TODO(fill): becomes last-known-good + degraded health later; the
    // contract under test now is "never crash, never propagate garbage".
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "astro-corrupt.json");
    defer fsutil.unlink(path) catch {};
    try fsutil.writeFileSync(path, "{\"schema\": 1, \"hostn");

    var s = try Store.load(std.testing.allocator, path);
    defer s.deinit();
    try std.testing.expectEqualStrings("astro", s.getHostname());
    try std.testing.expectEqualStrings("factory", s.getProvisioning());
}
