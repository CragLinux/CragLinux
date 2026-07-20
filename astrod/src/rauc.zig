//! RAUC backend: typed client for de.pengutronix.rauc over bus.zig
//! (docs/05 §5.1, docs/06 §5.3). Interface truth is the pinned source's
//! src/de.pengutronix.rauc.Installer.xml (rauc-1.15.2):
//!   methods  InstallBundle(s source, a{sv} args)
//!            InspectBundle(s source, a{sv} args) -> a{sv} info
//!            Info(s bundle) -> (s compatible, s version)   [deprecated]
//!            Mark(s state, s slot_identifier) -> (s slot_name, s message)
//!            GetSlotStatus() -> a(sa{sv})
//!            GetPrimary() -> s
//!   props    Operation s, LastError s, Progress (isi), Compatible s,
//!            Variant s, BootSlot s
//!   signal   Completed(i result)
//!
//! Reply dictionary keys are pinned to rauc-1.15.2 source:
//!  - GetSlotStatus slot dicts (service.c convert_slot_status_to_dict):
//!    "state"/"device"/"boot-status"/"bundle.version" are strings; other
//!    keys ("size" t, "installed.count" u, ...) are skipped generically.
//!    rauc 1.15 exposes no boot-attempts-left key on any bootloader
//!    backend, so SlotStatus.boot_attempts_left stays null in v1.
//!  - InspectBundle (manifest.c r_manifest_to_dict): root a{sv} with
//!    "update" -> v(v(a{sv})) containing "compatible" (s) and "version"
//!    (s) — note the DOUBLE variant (GVariantDict "v" insert format).
//!    InspectBundle IS on the bus in 1.15 (signature-first: check_bundle
//!    verifies against the keyring before the manifest is read), so the
//!    AD-021 gate never needs a shell-out to `rauc info`.
//!
//! Design rule: NO C types here — everything goes through bus.zig's typed
//! Bus/Message/Arg surface. Reply parsing is generic over a reader with
//! the bus.Message shape so the traversal logic is unit-tested offline
//! against hand-built expectation scripts (FakeMessage below), the same
//! way dinit.zig pins its wire frames.

const std = @import("std");
const bus_mod = @import("bus.zig");

pub const bus_name = "de.pengutronix.rauc";
pub const object_path = "/";
pub const interface = "de.pengutronix.rauc.Installer";

pub const Error = bus_mod.Error || error{
    /// Mapped from the daemon's D-Bus error on method calls; detail via
    /// Client.lastDbusError().
    RaucFailed,
};

/// One slot from GetSlotStatus, flattened to the fields GET /update/status
/// serves (docs/06 §5.3). Strings owned by the caller-provided allocator.
pub const SlotStatus = struct {
    /// e.g. "system.0" / "system.1".
    name: []const u8,
    /// "booted" | "inactive" | "active" (rauc state key).
    state: []const u8 = "",
    /// Bundle version installed in the slot ("" when never written).
    bundle_version: []const u8 = "",
    /// "good" | "bad" | "" (boot-status key, bootloader-backed).
    boot_status: []const u8 = "",
    /// Remaining boot attempts where the bootloader exposes it; always
    /// null on rauc 1.15 (no such slot-status key) — kept for the frozen
    /// v1 wire shape.
    boot_attempts_left: ?u32 = null,
    device: []const u8 = "",
};

/// GET /update/status core: slots + global installer state.
pub const Status = struct {
    /// From the BootSlot property.
    boot_slot: []const u8,
    /// From GetPrimary (the slot the bootloader will try first); null when
    /// the bootloader interface has no answer.
    primary: ?[]const u8,
    /// Operation property: "idle" | "installing" | ...
    operation: []const u8,
    last_error: []const u8,
    compatible: []const u8,
    slots: []SlotStatus,
};

/// InspectBundle output subset the AD-021 gate needs (signature-first:
/// RAUC only reports these after keyring verification).
pub const BundleInfo = struct {
    compatible: []const u8,
    version: []const u8,
};

pub const Progress = bus_mod.Progress;

/// Install source: local staged path or streamable URL — both go to
/// InstallBundle, which handles http(s) itself (docs/05 §5.1 NBD note).
pub const Source = union(enum) {
    path: [:0]const u8,
    url: [:0]const u8,

    pub fn value(self: Source) [:0]const u8 {
        return switch (self) {
            .path, .url => |s| s,
        };
    }
};

pub const InstallOptions = struct {
    /// AD-021: set when the client sent {"force": true} — bypasses
    /// astrod's monotonic-version gate (logged + surfaced in
    /// status.history). RAUC itself has no version gate, so this never
    /// reaches the wire; it rides along so call sites carry the policy
    /// decision explicitly.
    force: bool = false,
};

// ---- argument builders (XML-derived shapes, unit-tested) --------------------

/// InstallBundle(s source, a{sv} args) — args empty: astrod's policy runs
/// before the call, and rauc's own options (ignore-compatible, tls-*) are
/// deliberately not exposed through the v1 API.
pub fn installArgs(source: [:0]const u8) [2]bus_mod.Arg {
    return .{ .{ .s = source }, .{ .dict = &.{} } };
}

/// InspectBundle(s source, a{sv} args).
pub fn inspectArgs(source: [:0]const u8) [2]bus_mod.Arg {
    return .{ .{ .s = source }, .{ .dict = &.{} } };
}

/// Mark(s state, s slot_identifier).
pub fn markArgs(state: [:0]const u8, slot_identifier: [:0]const u8) [2]bus_mod.Arg {
    return .{ .{ .s = state }, .{ .s = slot_identifier } };
}

// ---- reply parsers (generic over the bus.Message reader shape) --------------

/// Read the string out of a variant of signature "s" and copy it.
fn dupeVariantString(allocator: std.mem.Allocator, reader: anytype) Error![]const u8 {
    if (!try reader.enterContainer('v', "s")) return error.InvalidReply;
    const s = try reader.readString();
    try reader.exitContainer();
    return allocator.dupe(u8, s) catch return error.OutOfMemory;
}

/// Parse a GetSlotStatus reply body: a(sa{sv}). The reader is positioned
/// at the start of the reply. Slot strings are copied into `allocator`
/// (an HTTP request arena — no piecewise cleanup on error).
pub fn parseSlotStatusReply(allocator: std.mem.Allocator, reader: anytype) Error![]SlotStatus {
    var slots: std.ArrayList(SlotStatus) = .empty;
    errdefer slots.deinit(allocator);

    if (!try reader.enterContainer('a', "(sa{sv})"))
        return slots.toOwnedSlice(allocator) catch error.OutOfMemory;
    while (try reader.enterContainer('r', "sa{sv}")) {
        var slot: SlotStatus = .{
            .name = allocator.dupe(u8, try reader.readString()) catch return error.OutOfMemory,
        };
        if (try reader.enterContainer('a', "{sv}")) {
            while (try reader.enterContainer('e', "sv")) {
                const key = try reader.readString();
                if (std.mem.eql(u8, key, "state")) {
                    slot.state = try dupeVariantString(allocator, reader);
                } else if (std.mem.eql(u8, key, "device")) {
                    slot.device = try dupeVariantString(allocator, reader);
                } else if (std.mem.eql(u8, key, "boot-status")) {
                    slot.boot_status = try dupeVariantString(allocator, reader);
                } else if (std.mem.eql(u8, key, "bundle.version")) {
                    slot.bundle_version = try dupeVariantString(allocator, reader);
                } else {
                    try reader.skip("v");
                }
                try reader.exitContainer(); // dict entry
            }
            try reader.exitContainer(); // a{sv}
        }
        try reader.exitContainer(); // struct
        slots.append(allocator, slot) catch return error.OutOfMemory;
    }
    try reader.exitContainer(); // outer array
    return slots.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Parse an InspectBundle reply body: a{sv} with "update" -> v(v(a{sv}))
/// holding "compatible" and "version". Missing keys stay "" — the AD-021
/// gate treats an unknown version conservatively (refuse unless forced).
///
/// DOUBLE-VARIANT TRAP (observed live on qemu-armv7, rauc 1.15.2):
/// r_manifest_to_dict inserts the group dicts with
/// `g_variant_dict_insert(&root_dict, "update", "v", ...)` — the "v"
/// format wraps the a{sv} in ANOTHER variant inside the entry's own
/// value variant. Scalar keys ("manifest-hash", "s") are single-wrapped.
/// Parsing this as v(a{sv}) fails with InvalidReply.
pub fn parseBundleInfo(allocator: std.mem.Allocator, reader: anytype) Error!BundleInfo {
    var info: BundleInfo = .{ .compatible = "", .version = "" };
    if (!try reader.enterContainer('a', "{sv}")) return info;
    while (try reader.enterContainer('e', "sv")) {
        const key = try reader.readString();
        if (std.mem.eql(u8, key, "update")) {
            if (!try reader.enterContainer('v', "v")) return error.InvalidReply;
            if (!try reader.enterContainer('v', "a{sv}")) return error.InvalidReply;
            if (try reader.enterContainer('a', "{sv}")) {
                while (try reader.enterContainer('e', "sv")) {
                    const ukey = try reader.readString();
                    if (std.mem.eql(u8, ukey, "compatible")) {
                        info.compatible = try dupeVariantString(allocator, reader);
                    } else if (std.mem.eql(u8, ukey, "version")) {
                        info.version = try dupeVariantString(allocator, reader);
                    } else {
                        try reader.skip("v");
                    }
                    try reader.exitContainer(); // dict entry
                }
                try reader.exitContainer(); // inner a{sv}
            }
            try reader.exitContainer(); // inner variant
            try reader.exitContainer(); // entry-value variant
        } else {
            try reader.skip("v");
        }
        try reader.exitContainer(); // dict entry
    }
    try reader.exitContainer(); // outer array
    return info;
}

// ---- client -----------------------------------------------------------------

/// Map bus-call failures: CallFailed means RAUC (or the bus policy)
/// rejected the method — surface as RaucFailed with the D-Bus error name
/// available via lastDbusError(); transport errors pass through.
fn mapCallError(err: bus_mod.Error) Error {
    return switch (err) {
        error.CallFailed => error.RaucFailed,
        else => |e| e,
    };
}

pub const Client = struct {
    bus: *bus_mod.Bus,

    pub fn init(bus: *bus_mod.Bus) Client {
        return .{ .bus = bus };
    }

    /// Full status snapshot (GetSlotStatus + properties), allocated from
    /// `allocator` (an HTTP request arena). GetSlotStatus failing fails
    /// the call; individual property reads degrade to "" (fail-soft, same
    /// stance as system.zig) and GetPrimary degrades to null — a booted
    /// system with a confused bootloader backend still gets a status page.
    pub fn status(self: *Client, allocator: std.mem.Allocator) Error!Status {
        var reply = self.bus.callMethod(bus_name, object_path, interface, "GetSlotStatus", &.{}) catch |err|
            return mapCallError(err);
        defer reply.deinit();
        const slots = try parseSlotStatusReply(allocator, &reply);

        return .{
            .boot_slot = self.propertyOrEmpty(allocator, "BootSlot"),
            .primary = self.getPrimary(allocator),
            .operation = self.propertyOrEmpty(allocator, "Operation"),
            .last_error = self.propertyOrEmpty(allocator, "LastError"),
            .compatible = self.propertyOrEmpty(allocator, "Compatible"),
            .slots = slots,
        };
    }

    fn propertyOrEmpty(self: *Client, allocator: std.mem.Allocator, member: [:0]const u8) []const u8 {
        return self.bus.getPropertyString(allocator, bus_name, object_path, interface, member) catch "";
    }

    /// GetPrimary() -> s; null when the bootloader interface errors (rauc
    /// returns a D-Bus error when it cannot determine a primary).
    pub fn getPrimary(self: *Client, allocator: std.mem.Allocator) ?[]const u8 {
        var reply = self.bus.callMethod(bus_name, object_path, interface, "GetPrimary", &.{}) catch return null;
        defer reply.deinit();
        const s = reply.readString() catch return null;
        return allocator.dupe(u8, s) catch null;
    }

    /// Signature-checked bundle metadata (InspectBundle with an empty
    /// a{sv}); the AD-021 version gate runs on the result BEFORE install.
    pub fn inspect(self: *Client, allocator: std.mem.Allocator, path: [:0]const u8) Error!BundleInfo {
        var reply = self.bus.callMethod(bus_name, object_path, interface, "InspectBundle", &inspectArgs(path)) catch |err|
            return mapCallError(err);
        defer reply.deinit();
        return parseBundleInfo(allocator, &reply);
    }

    /// Fire-and-monitor install: calls InstallBundle and returns; progress
    /// arrives via the Progress property / Completed signal (attach with
    /// watchProgress + the operations registry). The method call itself
    /// returns as soon as RAUC accepts the job.
    pub fn install(self: *Client, source: Source, opts: InstallOptions) Error!void {
        _ = opts; // policy already applied by the caller; see InstallOptions
        var reply = self.bus.callMethod(bus_name, object_path, interface, "InstallBundle", &installArgs(source.value())) catch |err|
            return mapCallError(err);
        reply.deinit();
    }

    /// Mark("good"|"bad"|"active", "booted"|"other"|<slot>) — reply
    /// (slot_name, message) is informational and dropped.
    fn mark(self: *Client, state: [:0]const u8, slot_identifier: [:0]const u8) Error!void {
        var reply = self.bus.callMethod(bus_name, object_path, interface, "Mark", &markArgs(state, slot_identifier)) catch |err|
            return mapCallError(err);
        reply.deinit();
    }

    pub fn markGood(self: *Client) Error!void {
        return self.mark("good", "booted");
    }

    pub fn markBad(self: *Client) Error!void {
        return self.mark("bad", "booted");
    }

    /// Make the other slot primary for next boot (rollback step,
    /// docs/05 §5.1): Mark("active", "other").
    pub fn activateOther(self: *Client) Error!void {
        return self.mark("active", "other");
    }

    /// Current Operation property ("idle" when nothing in flight) — the
    /// restart re-attach probe (docs/06 §7): a non-idle value right after
    /// daemon start means an install is running and a new operation
    /// record must be attached to it (update.Manager.attachInFlight).
    pub fn operation(self: *Client, allocator: std.mem.Allocator) Error![]u8 {
        return self.bus.getPropertyString(allocator, bus_name, object_path, interface, "Operation");
    }

    /// Progress property (isi).
    pub fn progress(self: *Client, allocator: std.mem.Allocator) Error!Progress {
        return self.bus.getPropertyProgress(allocator, bus_name, object_path, interface, "Progress");
    }

    /// LastError property.
    pub fn lastError(self: *Client, allocator: std.mem.Allocator) Error![]u8 {
        return self.bus.getPropertyString(allocator, bus_name, object_path, interface, "LastError");
    }

    /// D-Bus error name of the most recent failed call on this bus.
    pub fn lastDbusError(self: *Client) []const u8 {
        return self.bus.lastDbusError();
    }

    /// Subscribe to the installer's PropertiesChanged (progress) and
    /// Completed signals. `handler` runs on the bus thread (bus.zig
    /// rules: quick, no re-entry); wired to ops.Registry.update +
    /// events.publish by update.Manager.
    pub fn watchProgress(self: *Client, handler: bus_mod.SignalHandler, ctx: ?*anyopaque) Error!*bus_mod.Match {
        return self.bus.matchPropertiesChanged(bus_name, object_path, handler, ctx);
    }

    pub fn watchCompleted(self: *Client, handler: bus_mod.SignalHandler, ctx: ?*anyopaque) Error!*bus_mod.Match {
        return self.bus.matchSignal(bus_name, object_path, interface, "Completed", handler, ctx);
    }
};

// ---- offline test support ---------------------------------------------------

/// Scripted stand-in for bus.Message: each parser call is checked against
/// the next expected step, so a test script IS the hand-built expectation
/// of the exact container traversal (kinds, signatures, order) the XML
/// prescribes — drift in the parser OR the expectation fails the test.
/// Shared with update.zig's signal-parsing tests.
pub const FakeMessage = struct {
    script: []const Step,
    pos: usize = 0,

    pub const Step = union(enum) {
        /// Expected enterContainer(kind, contents) -> returns `result`
        /// (false = array exhausted).
        enter: struct { kind: u8, contents: []const u8, result: bool },
        exit,
        str: [:0]const u8,
        int32: i32,
        /// Expected skip(types).
        skipped: []const u8,
    };

    fn take(self: *FakeMessage) bus_mod.Error!Step {
        if (self.pos >= self.script.len) return error.InvalidReply;
        const step = self.script[self.pos];
        self.pos += 1;
        return step;
    }

    pub fn enterContainer(self: *FakeMessage, kind: u8, contents: [*:0]const u8) bus_mod.Error!bool {
        switch (try self.take()) {
            .enter => |e| {
                if (e.kind != kind or !std.mem.eql(u8, e.contents, std.mem.span(contents)))
                    return error.InvalidReply;
                return e.result;
            },
            else => return error.InvalidReply,
        }
    }

    pub fn exitContainer(self: *FakeMessage) bus_mod.Error!void {
        switch (try self.take()) {
            .exit => {},
            else => return error.InvalidReply,
        }
    }

    pub fn readString(self: *FakeMessage) bus_mod.Error![:0]const u8 {
        switch (try self.take()) {
            .str => |s| return s,
            else => return error.InvalidReply,
        }
    }

    pub fn readI32(self: *FakeMessage) bus_mod.Error!i32 {
        switch (try self.take()) {
            .int32 => |v| return v,
            else => return error.InvalidReply,
        }
    }

    pub fn skip(self: *FakeMessage, types: [*:0]const u8) bus_mod.Error!void {
        switch (try self.take()) {
            .skipped => |t| if (!std.mem.eql(u8, t, std.mem.span(types))) return error.InvalidReply,
            else => return error.InvalidReply,
        }
    }

    pub fn exhausted(self: *const FakeMessage) bool {
        return self.pos == self.script.len;
    }
};

// ---- tests ------------------------------------------------------------------

test "constants match the pinned interface XML" {
    // The strings are load-bearing (D-Bus routing); pin them so a typo
    // fails here and not against a live daemon.
    try std.testing.expectEqualStrings("de.pengutronix.rauc", bus_name);
    try std.testing.expectEqualStrings("de.pengutronix.rauc.Installer", interface);
    try std.testing.expectEqualStrings("/", object_path);
}

test "argument builders match the XML method signatures" {
    // InstallBundle(s, a{sv}) / InspectBundle(s, a{sv}): source string +
    // EMPTY option dict (astrod exposes none of rauc's install options).
    const install = installArgs("/data/.astro/staging/upload-1.raucb");
    try std.testing.expectEqualStrings("/data/.astro/staging/upload-1.raucb", install[0].s);
    try std.testing.expectEqual(@as(usize, 0), install[1].dict.len);

    const inspct = inspectArgs("/data/.astro/staging/upload-2.raucb");
    try std.testing.expectEqualStrings("/data/.astro/staging/upload-2.raucb", inspct[0].s);
    try std.testing.expectEqual(@as(usize, 0), inspct[1].dict.len);

    // Mark(s state, s slot_identifier) with the XML-documented values.
    const good = markArgs("good", "booted");
    try std.testing.expectEqualStrings("good", good[0].s);
    try std.testing.expectEqualStrings("booted", good[1].s);
    const activate = markArgs("active", "other");
    try std.testing.expectEqualStrings("active", activate[0].s);
    try std.testing.expectEqualStrings("other", activate[1].s);
}

test "parseSlotStatusReply walks a(sa{sv}) per the XML, skipping unknown keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Hand-built expectation for two slots as rauc-1.15.2 marshals them
    // (convert_slot_status_to_dict key set, non-string values skipped).
    var msg: FakeMessage = .{
        .script = &.{
            .{ .enter = .{ .kind = 'a', .contents = "(sa{sv})", .result = true } },
            // slot 1: system.0, booted/good, has a version
            .{ .enter = .{ .kind = 'r', .contents = "sa{sv}", .result = true } },
            .{ .str = "system.0" },
            .{ .enter = .{ .kind = 'a', .contents = "{sv}", .result = true } },
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "class" }, // uninteresting string key -> skip("v")
            .{ .skipped = "v" },
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "device" },
            .{ .enter = .{ .kind = 'v', .contents = "s", .result = true } },
            .{ .str = "/dev/disk/by-partlabel/rootfs.A" },
            .exit,
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "state" },
            .{ .enter = .{ .kind = 'v', .contents = "s", .result = true } },
            .{ .str = "booted" },
            .exit,
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "boot-status" },
            .{ .enter = .{ .kind = 'v', .contents = "s", .result = true } },
            .{ .str = "good" },
            .exit,
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "bundle.version" },
            .{ .enter = .{ .kind = 'v', .contents = "s", .result = true } },
            .{ .str = "0.1.0" },
            .exit,
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "size" }, // "t" variant in the wire — skipped generically
            .{ .skipped = "v" },
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = false } },
            .exit, // a{sv}
            .exit, // struct
            // slot 2: system.1, inactive, never installed (sparse dict)
            .{ .enter = .{ .kind = 'r', .contents = "sa{sv}", .result = true } },
            .{ .str = "system.1" },
            .{ .enter = .{ .kind = 'a', .contents = "{sv}", .result = true } },
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "state" },
            .{ .enter = .{ .kind = 'v', .contents = "s", .result = true } },
            .{ .str = "inactive" },
            .exit,
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = false } },
            .exit, // a{sv}
            .exit, // struct
            .{ .enter = .{ .kind = 'r', .contents = "sa{sv}", .result = false } },
            .exit, // outer array
        },
    };

    const slots = try parseSlotStatusReply(arena.allocator(), &msg);
    try std.testing.expect(msg.exhausted());
    try std.testing.expectEqual(@as(usize, 2), slots.len);
    try std.testing.expectEqualStrings("system.0", slots[0].name);
    try std.testing.expectEqualStrings("booted", slots[0].state);
    try std.testing.expectEqualStrings("good", slots[0].boot_status);
    try std.testing.expectEqualStrings("0.1.0", slots[0].bundle_version);
    try std.testing.expectEqualStrings("/dev/disk/by-partlabel/rootfs.A", slots[0].device);
    try std.testing.expect(slots[0].boot_attempts_left == null);
    try std.testing.expectEqualStrings("system.1", slots[1].name);
    try std.testing.expectEqualStrings("inactive", slots[1].state);
    try std.testing.expectEqualStrings("", slots[1].bundle_version);
    try std.testing.expectEqualStrings("", slots[1].boot_status);
}

test "parseBundleInfo extracts update.compatible/version, skips the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // r_manifest_to_dict order: manifest-hash, update(v a{sv}), bundle(...).
    var msg: FakeMessage = .{
        .script = &.{
            .{ .enter = .{ .kind = 'a', .contents = "{sv}", .result = true } },
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "manifest-hash" },
            .{ .skipped = "v" },
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "update" },
            // Double variant: the entry's value variant contains ANOTHER
            // variant holding the a{sv} (r_manifest_to_dict inserts the
            // group dicts with the "v" format — see the parser doc).
            .{ .enter = .{ .kind = 'v', .contents = "v", .result = true } },
            .{ .enter = .{ .kind = 'v', .contents = "a{sv}", .result = true } },
            .{ .enter = .{ .kind = 'a', .contents = "{sv}", .result = true } },
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "compatible" },
            .{ .enter = .{ .kind = 'v', .contents = "s", .result = true } },
            .{ .str = "astro-qemu-x86_64" },
            .exit,
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "version" },
            .{ .enter = .{ .kind = 'v', .contents = "s", .result = true } },
            .{ .str = "0.2.0" },
            .exit,
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "description" },
            .{ .skipped = "v" },
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = false } },
            .exit, // inner a{sv}
            .exit, // inner variant
            .exit, // entry-value variant
            .exit, // "update" dict entry
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = true } },
            .{ .str = "bundle" },
            .{ .skipped = "v" },
            .exit,
            .{ .enter = .{ .kind = 'e', .contents = "sv", .result = false } },
            .exit, // outer array
        },
    };

    const info = try parseBundleInfo(arena.allocator(), &msg);
    try std.testing.expect(msg.exhausted());
    try std.testing.expectEqualStrings("astro-qemu-x86_64", info.compatible);
    try std.testing.expectEqualStrings("0.2.0", info.version);
}

test "parseBundleInfo: missing update section degrades to empty fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var msg: FakeMessage = .{ .script = &.{
        .{ .enter = .{ .kind = 'a', .contents = "{sv}", .result = true } },
        .{ .enter = .{ .kind = 'e', .contents = "sv", .result = false } },
        .exit,
    } };
    const info = try parseBundleInfo(arena.allocator(), &msg);
    try std.testing.expectEqualStrings("", info.version);
    try std.testing.expectEqualStrings("", info.compatible);
}

test "parseSlotStatusReply: signature drift is an InvalidReply, not silence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A struct where the parser expects "sa{sv}" — e.g. an imagined future
    // rauc changing the tuple shape — must error loudly.
    var msg: FakeMessage = .{ .script = &.{
        .{ .enter = .{ .kind = 'a', .contents = "(sa{sv})", .result = true } },
        .{ .enter = .{ .kind = 'r', .contents = "sa{ss}", .result = true } },
    } };
    try std.testing.expectError(error.InvalidReply, parseSlotStatusReply(arena.allocator(), &msg));
}
