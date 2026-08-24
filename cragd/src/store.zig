//! Config store: one versioned JSON document at /data/config/crag.json,
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

pub const default_path = "/data/config/crag.json";
pub const schema_version: u32 = 1;

const max_document_len = 1024 * 1024;

pub const LoadError = error{
    /// Document schema is newer than this daemon understands. Downgrade-
    /// with-rewrite would lose data; the caller must surface this and stop.
    SchemaTooNew,
};

/// The persisted document. Unknown fields are tolerated on read (forward
/// compat within a schema); the fields here are the v1 set. The network
/// subtree is the M3 phase-3 ADDITIVE extension — schema stays 1 because
/// every field has a default (a phase-2 document parses unchanged).
pub const Config = struct {
    schema: u32 = schema_version,
    hostname: []const u8 = "crag",
    system: System = .{},
    api: Api = .{},
    network: Network = .{},

    pub const System = struct {
        /// Provisioning state machine (docs/07 §4):
        /// factory → provisioning → provisioned.
        provisioning: []const u8 = "factory",
        /// AP-mode control (docs/06 §5.2 GET,PUT /network/wifi/ap; M3
        /// phase 4, additive — schema stays 1).
        ap: Ap = .{},
    };

    pub const Ap = struct {
        /// Manual override for products that want on-demand AP: null =
        /// the provisioning state machine decides (the default), true =
        /// force the AP up, false = force it down even while
        /// unprovisioned. Written only by PUT /network/wifi/ap on
        /// authenticated surfaces — NEVER by the AP subset.
        enabled_override: ?bool = null,
    };

    /// Feature flags baked into the image defaults (docs/03 §6 `[api]`);
    /// defaults here mirror the stock board.toml values so a device with
    /// no document yet behaves like a freshly built image.
    pub const Api = struct {
        wifi: bool = true,
        ap_provisioning: bool = true,
        mdns: bool = true,
        lan_exposure: bool = false, // AD-025: LAN exposure defaults off
        /// Product policy "wired-is-provisioned" (docs/07 §4 wired path;
        /// M3 phase 4, additive): an ethernet lease + verified
        /// connectivity alone promotes to provisioned. Default false —
        /// the wired path then only surfaces availability.
        wired_provisions: bool = false,
    };

    /// Desired network state (docs/06 §5.2, docs/07 §2). Everything here
    /// is RENDERED into daemon-native files by netconf.zig — regenerable
    /// from this document at any time (factory-reset correctness).
    pub const Network = struct {
        /// Per-interface wired config, keyed by kernel interface name
        /// ("eth0"); absent interface = DHCP defaults.
        ethernet: std.json.ArrayHashMap(Ethernet) = .{},
        wifi: Wifi = .{},
        wan: Wan = .{},
    };

    pub const Ethernet = struct {
        ipv4: Ipv4 = .{},
        /// Static resolvers for this interface; win over DHCP-learned
        /// DNS in the rendered resolv.conf.
        dns: []const []const u8 = &.{},
    };

    pub const Ipv4 = struct {
        /// "dhcp" | "static" (docs/06 §5.2 wire shape).
        mode: []const u8 = "dhcp",
        /// mode=static only.
        address: ?[]const u8 = null,
        prefix: ?u8 = null,
        gateway: ?[]const u8 = null,
    };

    pub const Wifi = struct {
        /// The single (v1) configured station profile; null = none.
        /// Rendered as an iwd known-network PSK file (docs/07 §2).
        connection: ?WifiConnection = null,
    };

    pub const WifiConnection = struct {
        ssid: []const u8,
        /// WPA2/WPA3-PSK passphrase (EAP fields reserved — docs/06 §5.2).
        psk: []const u8,
    };

    pub const Wan = struct {
        /// Ordered interface-class preference; expressed as per-interface
        /// `metric` values in the rendered dhcpcd.conf (phase-3 decision:
        /// no rtnetlink route surgery).
        order: []const []const u8 = &.{ "ethernet", "wifi" },
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

    pub fn getWanOrder(self: *Store) []const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.network.wan.order;
    }

    pub fn getWifiConnection(self: *Store) ?Config.WifiConnection {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.network.wifi.connection;
    }

    pub fn getWiredProvisions(self: *Store) bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.api.wired_provisions;
    }

    pub fn getApEnabledOverride(self: *Store) ?bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.system.ap.enabled_override;
    }

    /// Persist the manual AP override (PUT /network/wifi/ap, docs/06
    /// §5.2 WifiApConfig): true forces the AP up, false forces it down,
    /// null returns control to the provisioning state machine.
    pub fn setApEnabledOverride(self: *Store, value: ?bool) !void {
        self.mu.lock();
        defer self.mu.unlock();
        self.config.system.ap.enabled_override = value;
        try self.persistLocked();
    }

    /// Persist a provisioning-state transition (the provision.Machine's
    /// persistState effect). `state` must be a static string
    /// (provision.State.jsonName) — the store never copies it.
    pub fn setProvisioning(self: *Store, state: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        self.config.system.provisioning = state;
        try self.persistLocked();
    }

    /// Per-interface wired config; null when the interface has no entry
    /// (callers apply Ethernet defaults = plain DHCP).
    pub fn getEthernet(self: *Store, iface: []const u8) ?Config.Ethernet {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.config.network.ethernet.map.get(iface);
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
    /// the document cragd-owned (0600) and chowns /data/config to
    /// cragd:crag-api 0710, so the unprivileged daemon can create the
    /// tmp file and rename; rewrites land 0640 cragd:cragd (the group
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

// ---- RFC 7396 JSON Merge Patch ---------------------------------------------

/// Apply a JSON Merge Patch (RFC 7396) to `target`, returning the merged
/// value. Semantics: a non-object patch replaces the target outright; an
/// object patch is applied member-wise, where `null` DELETES the member
/// and objects recurse (a member missing from the target merges against
/// an empty object, so nulls inside are dropped, per the RFC).
///
/// Values in the result may alias BOTH inputs — allocate everything
/// (target parse, patch parse, this call) from one per-request arena.
/// This is the PATCH /network/ethernet/{iface} engine: the handler
/// serializes the stored Ethernet object to a Value, merges the request
/// body, re-parses into Config.Ethernet (rejecting unknown fields), and
/// persists.
pub fn mergePatch(
    arena: std.mem.Allocator,
    target: std.json.Value,
    patch: std.json.Value,
) error{OutOfMemory}!std.json.Value {
    if (patch != .object) return patch;

    var result: std.json.ObjectMap = .empty;
    if (target == .object) {
        var it = target.object.iterator();
        while (it.next()) |entry| {
            try result.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    var pit = patch.object.iterator();
    while (pit.next()) |entry| {
        const key = entry.key_ptr.*;
        if (entry.value_ptr.* == .null) {
            _ = result.orderedRemove(key);
            continue;
        }
        const base = result.get(key) orelse std.json.Value.null;
        try result.put(arena, key, try mergePatch(arena, base, entry.value_ptr.*));
    }
    return .{ .object = result };
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
/// is 0640 (group crag-api readable, world-unreadable — docs/06 §6),
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
    var s = try Store.load(std.testing.allocator, "/nonexistent/crag.json");
    defer s.deinit();
    try std.testing.expectEqual(schema_version, s.getSchema());
    try std.testing.expectEqualStrings("crag", s.getHostname());
    try std.testing.expectEqualStrings("factory", s.getProvisioning());
    try std.testing.expect(!s.getLanExposure());
    try std.testing.expect(s.getApi().wifi);
    try std.testing.expect(s.getApi().ap_provisioning);
    try std.testing.expect(s.getApi().mdns);
    // Network defaults (phase 3, additive — schema stays 1).
    const order = s.getWanOrder();
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expectEqualStrings("ethernet", order[0]);
    try std.testing.expectEqualStrings("wifi", order[1]);
    try std.testing.expect(s.getWifiConnection() == null);
    try std.testing.expect(s.getEthernet("eth0") == null);
}

test "network subtree: parse, defaults inside entries, persist round-trip" {
    const allocator = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "crag-net.json");
    defer fsutil.unlink(path) catch {};
    try fsutil.writeFileSync(path,
        \\{"schema": 1,
        \\ "network": {
        \\   "ethernet": {
        \\     "eth0": {"ipv4": {"mode": "static", "address": "192.0.2.10",
        \\              "prefix": 24, "gateway": "192.0.2.1"},
        \\              "dns": ["192.0.2.53"]},
        \\     "eth1": {}
        \\   },
        \\   "wifi": {"connection": {"ssid": "crag-test", "psk": "hunter22"}},
        \\   "wan": {"order": ["wifi", "ethernet"]}
        \\ }}
    );

    var s = try Store.load(allocator, path);
    defer s.deinit();

    const eth0 = s.getEthernet("eth0").?;
    try std.testing.expectEqualStrings("static", eth0.ipv4.mode);
    try std.testing.expectEqualStrings("192.0.2.10", eth0.ipv4.address.?);
    try std.testing.expectEqual(@as(u8, 24), eth0.ipv4.prefix.?);
    try std.testing.expectEqualStrings("192.0.2.1", eth0.ipv4.gateway.?);
    try std.testing.expectEqual(@as(usize, 1), eth0.dns.len);
    // Empty entry inherits the struct defaults (plain DHCP).
    const eth1 = s.getEthernet("eth1").?;
    try std.testing.expectEqualStrings("dhcp", eth1.ipv4.mode);
    try std.testing.expect(eth1.ipv4.address == null);

    const conn = s.getWifiConnection().?;
    try std.testing.expectEqualStrings("crag-test", conn.ssid);
    try std.testing.expectEqualStrings("hunter22", conn.psk);
    try std.testing.expectEqualStrings("wifi", s.getWanOrder()[0]);

    // Round-trip: persist and reload must preserve the whole subtree.
    try s.persist();
    var s2 = try Store.load(allocator, path);
    defer s2.deinit();
    try std.testing.expectEqualStrings("192.0.2.10", s2.getEthernet("eth0").?.ipv4.address.?);
    try std.testing.expectEqualStrings("crag-test", s2.getWifiConnection().?.ssid);
    try std.testing.expectEqualStrings("wifi", s2.getWanOrder()[0]);
    try std.testing.expectEqual(schema_version, s2.getSchema());
}

test "persist writes atomically, fsyncs, and load round-trips all subtrees" {
    const allocator = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "crag.json");
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
    const path = fsutil.testTmpPath(&path_buf, "crag-v2.json");
    defer fsutil.unlink(path) catch {};
    try fsutil.writeFileSync(path,
        \\{"schema": 2, "hostname": "from-the-future"}
    );

    try std.testing.expectError(LoadError.SchemaTooNew, Store.load(std.testing.allocator, path));
}

test "load tolerates unknown fields from newer writers within the schema" {
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "crag-fwd.json");
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

// ---- mergePatch tests (RFC 7396 semantics) ----------------------------------

fn parseValue(arena: std.mem.Allocator, json_text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{});
}

fn expectMerged(arena: std.mem.Allocator, target_json: []const u8, patch_json: []const u8, want_json: []const u8) !void {
    const target = try parseValue(arena, target_json);
    const patch = try parseValue(arena, patch_json);
    const got = try mergePatch(arena, target, patch);
    const got_text = try std.json.Stringify.valueAlloc(arena, got, .{});
    const want = try parseValue(arena, want_json);
    const want_text = try std.json.Stringify.valueAlloc(arena, want, .{});
    try std.testing.expectEqualStrings(want_text, got_text);
}

test "mergePatch: RFC 7396 core semantics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Replacement, addition, and null-deletes (RFC 7396 §1 example).
    try expectMerged(arena,
        \\{"a":"b","c":{"d":"e","f":"g"}}
    ,
        \\{"a":"z","c":{"f":null}}
    ,
        \\{"a":"z","c":{"d":"e"}}
    );
    // Non-object patch replaces outright.
    try expectMerged(arena, "{\"a\":1}", "[1,2]", "[1,2]");
    try expectMerged(arena, "{\"a\":1}", "null", "null");
    // Patch object onto a non-object target: target discarded, nulls
    // dropped (merge against empty object).
    try expectMerged(arena, "[\"x\"]", "{\"a\":1,\"b\":null}", "{\"a\":1}");
    // Deleting a key that does not exist is a no-op.
    try expectMerged(arena, "{\"a\":1}", "{\"b\":null}", "{\"a\":1}");
    // Arrays replace wholesale (no element-wise merge).
    try expectMerged(arena, "{\"dns\":[\"1.1.1.1\",\"9.9.9.9\"]}", "{\"dns\":[\"8.8.8.8\"]}", "{\"dns\":[\"8.8.8.8\"]}");
    // Nested object creation through a missing member.
    try expectMerged(arena, "{}", "{\"a\":{\"bb\":{\"ccc\":null}}}", "{\"a\":{\"bb\":{}}}");
}

test "mergePatch: the PATCH /network/ethernet/{iface} shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // dhcp → static without resending dns; then null resets a field.
    try expectMerged(arena,
        \\{"ipv4":{"mode":"dhcp","address":null,"prefix":null,"gateway":null},"dns":["192.0.2.53"]}
    ,
        \\{"ipv4":{"mode":"static","address":"192.0.2.10","prefix":24,"gateway":"192.0.2.1"}}
    ,
        \\{"ipv4":{"mode":"static","address":"192.0.2.10","prefix":24,"gateway":"192.0.2.1"},"dns":["192.0.2.53"]}
    );
    try expectMerged(arena,
        \\{"ipv4":{"mode":"static","address":"192.0.2.10","prefix":24,"gateway":"192.0.2.1"},"dns":["192.0.2.53"]}
    ,
        \\{"ipv4":{"mode":"dhcp","address":null,"prefix":null,"gateway":null},"dns":null}
    ,
        \\{"ipv4":{"mode":"dhcp"}}
    );
}

test "phase-4 additive fields: defaults, parse, persist round-trip (schema stays 1)" {
    const allocator = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "crag-p4.json");
    defer fsutil.unlink(path) catch {};

    // Defaults on a document that predates phase 4.
    var d = try Store.load(allocator, "/nonexistent/crag.json");
    defer d.deinit();
    try std.testing.expect(!d.getWiredProvisions());
    try std.testing.expect(d.getApEnabledOverride() == null);

    // Parse both fields; unrelated fields keep their defaults.
    try fsutil.writeFileSync(path,
        \\{"schema": 1,
        \\ "api": {"wired_provisions": true},
        \\ "system": {"provisioning": "provisioning",
        \\            "ap": {"enabled_override": false}}}
    );
    var s = try Store.load(allocator, path);
    defer s.deinit();
    try std.testing.expect(s.getWiredProvisions());
    try std.testing.expectEqual(@as(?bool, false), s.getApEnabledOverride());
    try std.testing.expect(s.getApi().mdns);

    // setProvisioning persists atomically and round-trips.
    try s.setProvisioning("provisioned");
    var s2 = try Store.load(allocator, path);
    defer s2.deinit();
    try std.testing.expectEqualStrings("provisioned", s2.getProvisioning());
    try std.testing.expect(s2.getWiredProvisions());
    try std.testing.expectEqual(@as(?bool, false), s2.getApEnabledOverride());
    try std.testing.expectEqual(schema_version, s2.getSchema());
}

test "load falls back to defaults on a corrupt document" {
    // TODO(fill): becomes last-known-good + degraded health later; the
    // contract under test now is "never crash, never propagate garbage".
    var path_buf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&path_buf, "crag-corrupt.json");
    defer fsutil.unlink(path) catch {};
    try fsutil.writeFileSync(path, "{\"schema\": 1, \"hostn");

    var s = try Store.load(std.testing.allocator, path);
    defer s.deinit();
    try std.testing.expectEqualStrings("crag", s.getHostname());
    try std.testing.expectEqualStrings("factory", s.getProvisioning());
}
