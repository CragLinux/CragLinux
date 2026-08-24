//! sd-bus (basu) wrapper — THE only module where C bus types appear
//! (docs/06 §3, AD-016). Everything above this file sees typed Zig:
//! reconcilers and backends (rauc.zig, later iwd) build on Bus/Message/Arg.
//!
//! Threading model (phase-2 decision, do not change casually):
//!  - sd_bus handles are NOT thread-safe. All sd-bus work happens under
//!    `self.mu`, whether it originates from the dedicated bus thread
//!    (run(): sd_bus_process/poll loop) or from an HTTP handler thread
//!    calling callMethod()/getProperty*() (each locks mu for the duration
//!    of the synchronous call — sd_bus_call does its own inner dispatch,
//!    which is fine because the loop never holds mu while poll()ing).
//!  - The loop polls the bus fd *and* an eventfd; external callers kick
//!    the eventfd after touching the bus so the loop re-reads its timeout
//!    and write-queue state immediately.
//!  - Signal callbacks (matchSignal) run on the bus thread with mu HELD:
//!    they must be quick and must NOT call back into Bus (deadlock).
//!    Publish into a queue/ring (events.zig) and return.
//!
//! Unit tests never require a live daemon: connectSystem() fails cleanly
//! with error.NoBusSocket when /run/dbus/system_bus_socket is absent, and
//! the marshaling tests drive a socketpair-backed bus that is never
//! connected to anything (message building/sealing/reading is local).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const sync = @import("sync.zig");
const fsutil = @import("fsutil.zig");

pub const c = @cImport({
    @cInclude("basu/sd-bus.h");
});

/// Well-known system bus socket (musl/chimera images; dbus-daemon dinit
/// service creates it). sd_bus_open_system would find it itself; probing
/// first turns "no daemon" into a typed error instead of an errno guess.
pub const system_bus_socket = "/run/dbus/system_bus_socket";

pub const Error = error{
    /// /run/dbus/system_bus_socket does not exist (dbus-daemon not up, or
    /// a unit-test environment). Retryable — see connectSystemRetry.
    NoBusSocket,
    /// Socket exists but the connection/handshake failed.
    ConnectFailed,
    /// The peer closed or the bus disconnected mid-flight.
    Disconnected,
    /// A method call failed; lastDbusError() has the D-Bus error name.
    CallFailed,
    /// Reply arrived but did not match the expected signature.
    InvalidReply,
    /// Marshaling input rejected (bad string, container mismatch).
    InvalidArgs,
    OutOfMemory,
};

fn errnoFromRet(r: c_int) i32 {
    return -r; // sd-bus returns negative errno
}

// ---- typed argument marshaling ---------------------------------------------

/// Basic value inside an a{sv} dict (the subset RAUC's API needs).
pub const Value = union(enum) {
    s: [:0]const u8,
    b: bool,
    u: u32,

    fn signature(self: Value) [*:0]const u8 {
        return switch (self) {
            .s => "s",
            .b => "b",
            .u => "u",
        };
    }
};

pub const DictEntry = struct {
    key: [:0]const u8,
    value: Value,
};

/// One method-call argument. Strings are borrowed for the duration of the
/// call (sd-bus copies them into the message body immediately).
pub const Arg = union(enum) {
    s: [:0]const u8,
    b: bool,
    u: u32,
    /// Marshals as a{sv}; pass &.{} for an empty dict.
    dict: []const DictEntry,
};

// ---- reply/message reading -------------------------------------------------

/// A borrowed-or-owned sd_bus_message with typed readers. Returned string
/// slices point into the message body and live until deinit().
pub const Message = struct {
    m: *c.sd_bus_message,
    owned: bool,

    pub fn deinit(self: *Message) void {
        if (self.owned) _ = c.sd_bus_message_unref(self.m);
        self.* = undefined;
    }

    pub fn readString(self: *Message) Error![:0]const u8 {
        var p: [*c]const u8 = null;
        if (c.sd_bus_message_read_basic(self.m, 's', @ptrCast(&p)) < 0) return error.InvalidReply;
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    }

    pub fn readObjectPath(self: *Message) Error![:0]const u8 {
        var p: [*c]const u8 = null;
        if (c.sd_bus_message_read_basic(self.m, 'o', @ptrCast(&p)) < 0) return error.InvalidReply;
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    }

    pub fn readBool(self: *Message) Error!bool {
        var v: c_int = 0;
        if (c.sd_bus_message_read_basic(self.m, 'b', &v) < 0) return error.InvalidReply;
        return v != 0;
    }

    pub fn readU32(self: *Message) Error!u32 {
        var v: u32 = 0;
        if (c.sd_bus_message_read_basic(self.m, 'u', &v) < 0) return error.InvalidReply;
        return v;
    }

    pub fn readI32(self: *Message) Error!i32 {
        var v: i32 = 0;
        if (c.sd_bus_message_read_basic(self.m, 'i', &v) < 0) return error.InvalidReply;
        return v;
    }

    pub fn readI16(self: *Message) Error!i16 {
        var v: i16 = 0;
        if (c.sd_bus_message_read_basic(self.m, 'n', &v) < 0) return error.InvalidReply;
        return v;
    }

    pub fn readU64(self: *Message) Error!u64 {
        var v: u64 = 0;
        if (c.sd_bus_message_read_basic(self.m, 't', &v) < 0) return error.InvalidReply;
        return v;
    }

    /// Enter a container ('a' array, 'r' struct, 'e' dict entry,
    /// 'v' variant). Returns false when the enclosing array is exhausted
    /// (the "iterate an array of containers" idiom).
    pub fn enterContainer(self: *Message, kind: u8, contents: [*:0]const u8) Error!bool {
        const r = c.sd_bus_message_enter_container(self.m, kind, contents);
        if (r < 0) return error.InvalidReply;
        return r > 0;
    }

    pub fn exitContainer(self: *Message) Error!void {
        if (c.sd_bus_message_exit_container(self.m) < 0) return error.InvalidReply;
    }

    /// Peek the type of the next element: returns null at end-of-container,
    /// else the type character (and for containers, `contents` signature is
    /// available via a second peek inside enterContainer).
    pub fn peekType(self: *Message) Error!?u8 {
        var t: u8 = 0;
        var contents: [*c]const u8 = null;
        const r = c.sd_bus_message_peek_type(self.m, @ptrCast(&t), &contents);
        if (r < 0) return error.InvalidReply;
        if (r == 0) return null;
        return t;
    }

    /// Skip one complete value of the given signature (e.g. "v" inside an
    /// a{sv} whose key was not interesting). `null` skips exactly one
    /// complete value of whatever type comes next (sd-bus contract).
    pub fn skip(self: *Message, types: ?[*:0]const u8) Error!void {
        if (c.sd_bus_message_skip(self.m, types) < 0) return error.InvalidReply;
    }

    /// Skip everything left in the currently entered container, then exit
    /// it — the "I am done with this level" idiom for partial reads.
    pub fn skipRestAndExit(self: *Message) Error!void {
        while (try self.peekType() != null) try self.skip(null);
        try self.exitContainer();
    }

    /// Like peekType but also yields the container-contents signature
    /// (needed to enter a variant of unknown type). The contents pointer
    /// is only valid until the message cursor moves — copy it out.
    pub fn peekTypeFull(self: *Message) Error!?PeekedType {
        var t: u8 = 0;
        var contents: [*c]const u8 = null;
        const r = c.sd_bus_message_peek_type(self.m, @ptrCast(&t), &contents);
        if (r < 0) return error.InvalidReply;
        if (r == 0) return null;
        return .{ .t = t, .contents = if (contents) |p| @as([*:0]const u8, @ptrCast(p)) else null };
    }

    /// Object path of a signal/message header (null when unset) — the
    /// routing key for tree-scoped PropertiesChanged/InterfacesAdded
    /// handlers (each iwd Device/Station/Network is its own object).
    pub fn path(self: *Message) ?[:0]const u8 {
        const p = c.sd_bus_message_get_path(self.m) orelse return null;
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    }

    /// Interface of a signal header (null when unset).
    pub fn interfaceName(self: *Message) ?[:0]const u8 {
        const p = c.sd_bus_message_get_interface(self.m) orelse return null;
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    }

    /// Member of a signal header (null when unset).
    pub fn member(self: *Message) ?[:0]const u8 {
        const p = c.sd_bus_message_get_member(self.m) orelse return null;
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    }

    pub fn signature(self: *Message) [:0]const u8 {
        const sig = c.sd_bus_message_get_signature(self.m, 1);
        if (sig == null) return "";
        return std.mem.span(@as([*:0]const u8, @ptrCast(sig)));
    }

    // ---- ObjectManager-shaped typed reads (see the section below for the
    // wire shapes and their iwd source-of-truth citations) ----------------

    /// Parse a GetManagedObjects reply (a{oa{sa{sv}}}) into an owned tree.
    /// Cursor must sit at the start of the reply body.
    pub fn readManagedObjects(self: *Message, gpa: std.mem.Allocator) Error!ObjectTree {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var objects: std.ArrayList(ObjectEntry) = .empty;
        if (!try self.enterContainer('a', "{oa{sa{sv}}}")) return error.InvalidReply;
        while (try self.enterContainer('e', "oa{sa{sv}}")) {
            const obj_path = try self.readObjectPath();
            const interfaces = try self.readInterfaceArray(a);
            try self.exitContainer(); // e
            objects.append(a, .{
                .path = a.dupeZ(u8, obj_path) catch return error.OutOfMemory,
                .interfaces = interfaces,
            }) catch return error.OutOfMemory;
        }
        try self.exitContainer(); // a

        return .{ .arena = arena, .objects = objects.toOwnedSlice(a) catch return error.OutOfMemory };
    }

    /// Parse an InterfacesAdded signal body (oa{sa{sv}}) into a one-object
    /// tree (same consumers as readManagedObjects).
    pub fn readInterfacesAdded(self: *Message, gpa: std.mem.Allocator) Error!ObjectTree {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const obj_path = try self.readObjectPath();
        const interfaces = try self.readInterfaceArray(a);

        const objects = a.alloc(ObjectEntry, 1) catch return error.OutOfMemory;
        objects[0] = .{
            .path = a.dupeZ(u8, obj_path) catch return error.OutOfMemory,
            .interfaces = interfaces,
        };
        return .{ .arena = arena, .objects = objects };
    }

    /// Parse an InterfacesRemoved signal body (oas).
    pub fn readInterfacesRemoved(self: *Message, gpa: std.mem.Allocator) Error!RemovedInterfaces {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const obj_path = try self.readObjectPath();
        const names = try self.readStringArray(a);
        return .{
            .arena = arena,
            .path = a.dupeZ(u8, obj_path) catch return error.OutOfMemory,
            .interfaces = names,
        };
    }

    /// Parse a PropertiesChanged signal body (sa{sv}as).
    pub fn readPropertiesChanged(self: *Message, gpa: std.mem.Allocator) Error!PropertiesUpdate {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const iface = try self.readString();
        const changed = try self.readPropArray(a);
        const invalidated = try self.readStringArray(a);
        return .{
            .arena = arena,
            .interface = a.dupeZ(u8, iface) catch return error.OutOfMemory,
            .changed = changed,
            .invalidated = invalidated,
        };
    }

    /// a{sa{sv}} at the cursor → owned InterfaceProps slice.
    fn readInterfaceArray(self: *Message, a: std.mem.Allocator) Error![]InterfaceProps {
        var list: std.ArrayList(InterfaceProps) = .empty;
        if (!try self.enterContainer('a', "{sa{sv}}")) return error.InvalidReply;
        while (try self.enterContainer('e', "sa{sv}")) {
            const name = try self.readString();
            const props = try self.readPropArray(a);
            try self.exitContainer(); // e
            list.append(a, .{
                .name = a.dupeZ(u8, name) catch return error.OutOfMemory,
                .props = props,
            }) catch return error.OutOfMemory;
        }
        try self.exitContainer(); // a
        return list.toOwnedSlice(a) catch return error.OutOfMemory;
    }

    /// a{sv} at the cursor → owned Prop slice.
    pub fn readPropArray(self: *Message, a: std.mem.Allocator) Error![]Prop {
        var list: std.ArrayList(Prop) = .empty;
        if (!try self.enterContainer('a', "{sv}")) return error.InvalidReply;
        while (try self.enterContainer('e', "sv")) {
            const name = try self.readString();
            const value = try self.readVariantValue(a);
            try self.exitContainer(); // e
            list.append(a, .{
                .name = a.dupeZ(u8, name) catch return error.OutOfMemory,
                .value = value,
            }) catch return error.OutOfMemory;
        }
        try self.exitContainer(); // a
        return list.toOwnedSlice(a) catch return error.OutOfMemory;
    }

    /// One variant at the cursor → PropValue (container contents skipped
    /// as .unsupported, signature retained).
    fn readVariantValue(self: *Message, a: std.mem.Allocator) Error!PropValue {
        const peeked = (try self.peekTypeFull()) orelse return error.InvalidReply;
        if (peeked.t != 'v') return error.InvalidReply;
        const contents = peeked.contents orelse return error.InvalidReply;
        // Copy before the cursor moves (sd-bus contents pointer lifetime).
        const sig = a.dupeZ(u8, std.mem.span(contents)) catch return error.OutOfMemory;

        if (!try self.enterContainer('v', sig.ptr)) return error.InvalidReply;
        const value: PropValue = switch (sig[0]) {
            's' => .{ .s = a.dupeZ(u8, try self.readString()) catch return error.OutOfMemory },
            'o' => .{ .o = a.dupeZ(u8, try self.readObjectPath()) catch return error.OutOfMemory },
            'b' => .{ .b = try self.readBool() },
            'y' => blk: {
                var v: u8 = 0;
                if (c.sd_bus_message_read_basic(self.m, 'y', &v) < 0) return error.InvalidReply;
                break :blk .{ .y = v };
            },
            'n' => blk: {
                var v: i16 = 0;
                if (c.sd_bus_message_read_basic(self.m, 'n', &v) < 0) return error.InvalidReply;
                break :blk .{ .n = v };
            },
            'q' => blk: {
                var v: u16 = 0;
                if (c.sd_bus_message_read_basic(self.m, 'q', &v) < 0) return error.InvalidReply;
                break :blk .{ .q = v };
            },
            'i' => .{ .i = try self.readI32() },
            'u' => .{ .u = try self.readU32() },
            'x' => blk: {
                var v: i64 = 0;
                if (c.sd_bus_message_read_basic(self.m, 'x', &v) < 0) return error.InvalidReply;
                break :blk .{ .x = v };
            },
            't' => .{ .t = try self.readU64() },
            'd' => blk: {
                var v: f64 = 0;
                if (c.sd_bus_message_read_basic(self.m, 'd', &v) < 0) return error.InvalidReply;
                break :blk .{ .d = v };
            },
            else => blk: {
                try self.skip(sig.ptr);
                break :blk .{ .unsupported = sig };
            },
        };
        try self.exitContainer(); // v
        return value;
    }

    /// "as" at the cursor → owned string slice.
    fn readStringArray(self: *Message, a: std.mem.Allocator) Error![]const [:0]const u8 {
        var list: std.ArrayList([:0]const u8) = .empty;
        if (!try self.enterContainer('a', "s")) {
            // An empty array still "enters" per sd-bus (returns > 0) and the
            // loop below terminates on peekType; entering can only report
            // false for the enclosing-array-exhausted idiom, which cannot
            // happen at this call site.
            return error.InvalidReply;
        }
        while (try self.peekType() != null) {
            const s = try self.readString();
            list.append(a, a.dupeZ(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
        try self.exitContainer();
        return list.toOwnedSlice(a) catch return error.OutOfMemory;
    }
};

/// Result of Message.peekTypeFull.
pub const PeekedType = struct {
    t: u8,
    contents: ?[*:0]const u8,
};

/// RAUC's Progress property: (isi) = percentage, message, nesting depth
/// (source of truth: de.pengutronix.rauc.Installer.xml in the pinned
/// rauc-1.15.2 tree — note it is (isi), not the (iis) some docs claim).
pub const Progress = struct {
    percentage: i32,
    message: [:0]const u8,
    depth: i32,
};

// ---- org.freedesktop.DBus.ObjectManager (iwd's tree shape) ------------------
//
// iwd (net.connman.iwd) registers an ObjectManager at path "/" (iwd-3.12
// src/main.c: l_dbus_object_manager_enable(dbus, "/")) with Adapter/Device/
// Station/Network/KnownNetwork objects under /net/connman/iwd. The wire
// shapes below are verified against iwd's bundled ell implementation
// (iwd-3.12 ell/dbus-service.c object_manager_setup_func):
//   GetManagedObjects  → a{oa{sa{sv}}}
//   InterfacesAdded    → oa{sa{sv}}
//   InterfacesRemoved  → oas
// plus org.freedesktop.DBus.Properties.PropertiesChanged → sa{sv}as.

pub const object_manager_interface = "org.freedesktop.DBus.ObjectManager";

/// One property value out of an a{sv}. Basic types are read typed; any
/// container-valued variant (arrays, structs, nested dicts) is skipped and
/// reported as `.unsupported` carrying the variant's contents signature —
/// callers that need such a value read the raw Message themselves.
pub const PropValue = union(enum) {
    s: [:0]const u8,
    o: [:0]const u8,
    b: bool,
    y: u8,
    n: i16,
    q: u16,
    i: i32,
    u: u32,
    x: i64,
    t: u64,
    d: f64,
    unsupported: [:0]const u8,
};

pub const Prop = struct {
    name: [:0]const u8,
    value: PropValue,
};

pub const InterfaceProps = struct {
    name: [:0]const u8,
    props: []Prop,

    pub fn get(self: *const InterfaceProps, prop_name: []const u8) ?PropValue {
        for (self.props) |p| {
            if (std.mem.eql(u8, p.name, prop_name)) return p.value;
        }
        return null;
    }
};

pub const ObjectEntry = struct {
    path: [:0]const u8,
    interfaces: []InterfaceProps,

    pub fn interface(self: *const ObjectEntry, iface_name: []const u8) ?*const InterfaceProps {
        for (self.interfaces) |*ip| {
            if (std.mem.eql(u8, ip.name, iface_name)) return ip;
        }
        return null;
    }
};

/// Owned parse of a managed-objects tree (or a single InterfacesAdded
/// object). All strings are copies in the arena — independent of the
/// source Message's lifetime.
pub const ObjectTree = struct {
    arena: std.heap.ArenaAllocator,
    objects: []ObjectEntry,

    pub fn deinit(self: *ObjectTree) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Find `iface_name` on the object at `obj_path`.
    pub fn find(self: *const ObjectTree, obj_path: []const u8, iface_name: []const u8) ?*const InterfaceProps {
        for (self.objects) |*obj| {
            if (std.mem.eql(u8, obj.path, obj_path)) return obj.interface(iface_name);
        }
        return null;
    }
};

/// Owned parse of an InterfacesRemoved signal body (oas).
pub const RemovedInterfaces = struct {
    arena: std.heap.ArenaAllocator,
    path: [:0]const u8,
    interfaces: []const [:0]const u8,

    pub fn deinit(self: *RemovedInterfaces) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Owned parse of a PropertiesChanged signal body (sa{sv}as). Route by
/// the signal's object path (Message.path()) — with a path_namespace
/// match one handler covers the whole iwd tree.
pub const PropertiesUpdate = struct {
    arena: std.heap.ArenaAllocator,
    interface: [:0]const u8,
    changed: []Prop,
    invalidated: []const [:0]const u8,

    pub fn deinit(self: *PropertiesUpdate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Signal callback. `msg` is borrowed (do not deinit); runs on the bus
/// thread with the bus mutex held — be quick, never call back into Bus.
pub const SignalHandler = *const fn (ctx: ?*anyopaque, msg: *Message) void;

/// Cancellation handle for an installed signal match.
pub const Match = struct {
    slot: *c.sd_bus_slot,
    bus: *Bus,
    trampoline: *Trampoline,

    /// Remove the match and free the trampoline. Must not be called from
    /// inside a signal callback (mutex is not recursive).
    pub fn cancel(self: *Match) void {
        self.bus.mu.lock();
        _ = c.sd_bus_slot_unref(self.slot);
        self.bus.mu.unlock();
        self.bus.gpa.destroy(self.trampoline);
        self.bus.gpa.destroy(self);
    }
};

const Trampoline = struct {
    handler: SignalHandler,
    ctx: ?*anyopaque,
};

fn signalTrampoline(m: ?*c.sd_bus_message, userdata: ?*anyopaque, _: [*c]c.sd_bus_error) callconv(.c) c_int {
    const tramp: *Trampoline = @ptrCast(@alignCast(userdata.?));
    var msg: Message = .{ .m = m.?, .owned = false };
    tramp.handler(tramp.ctx, &msg);
    return 0;
}

// ---- the bus ----------------------------------------------------------------

pub const Bus = struct {
    gpa: std.mem.Allocator,
    bus: *c.sd_bus,
    /// Serializes ALL sd-bus access (handles are not thread-safe).
    mu: sync.Mutex = .{},
    /// eventfd the loop polls alongside the bus fd; kicked after external
    /// calls and on stop() so the loop re-evaluates immediately.
    wake_fd: posix.fd_t,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    // Last D-Bus error (name\0message\0), captured under mu by call paths.
    last_error_buf: [256]u8 = @splat(0),
    last_error_len: usize = 0,

    /// Connect to the system bus. Fails with error.NoBusSocket when the
    /// daemon's socket is absent (unit tests, early boot) — callers decide
    /// whether to retry (connectSystemRetry) or degrade.
    pub fn connectSystem(gpa: std.mem.Allocator) Error!*Bus {
        // Probe only when sd-bus would use the default socket; an explicit
        // DBUS_SYSTEM_BUS_ADDRESS (tests, containers) is trusted as-is.
        // (std.c.getenv: astrod links musl anyway; std.posix.getenv is gone
        // in Zig 0.16 and Environ wants the process-init plumbing.)
        if (std.c.getenv("DBUS_SYSTEM_BUS_ADDRESS") == null) {
            if (!fsutil.pathExists(system_bus_socket)) return error.NoBusSocket;
        }
        var sd: ?*c.sd_bus = null;
        const r = c.sd_bus_open_system(&sd);
        if (r < 0 or sd == null) return error.ConnectFailed;
        errdefer _ = c.sd_bus_unref(sd);
        return initCommon(gpa, sd.?);
    }

    fn initCommon(gpa: std.mem.Allocator, sd: *c.sd_bus) Error!*Bus {
        const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd_rc) != .SUCCESS) return error.ConnectFailed;
        const self = gpa.create(Bus) catch return error.OutOfMemory;
        self.* = .{ .gpa = gpa, .bus = sd, .wake_fd = @intCast(efd_rc) };
        return self;
    }

    /// Stop the loop thread (if started), close and free everything.
    pub fn deinit(self: *Bus) void {
        self.stop();
        _ = c.sd_bus_flush_close_unref(self.bus);
        _ = linux.close(self.wake_fd);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Spawn the dedicated bus thread executing run(). Idempotent.
    pub fn start(self: *Bus) !void {
        if (self.thread != null) return;
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Signal the loop to exit and join the thread. Idempotent.
    pub fn stop(self: *Bus) void {
        const t = self.thread orelse return;
        self.stop_flag.store(true, .release);
        self.kick();
        t.join();
        self.thread = null;
    }

    /// The bus thread loop: dispatch everything ready (under mu), then
    /// poll the bus fd + wake eventfd without holding mu, honoring
    /// sd-bus's own timeout. Runs until stop().
    pub fn run(self: *Bus) void {
        while (!self.stop_flag.load(.acquire)) {
            self.mu.lock();
            // Drain: each sd_bus_process call handles at most one message.
            while (true) {
                const r = c.sd_bus_process(self.bus, null);
                if (r <= 0) break; // 0 = nothing more; <0 = disconnect/error
            }
            const bus_fd = c.sd_bus_get_fd(self.bus);
            const bus_events = c.sd_bus_get_events(self.bus);
            var timeout_usec: u64 = std.math.maxInt(u64);
            _ = c.sd_bus_get_timeout(self.bus, &timeout_usec);
            self.mu.unlock();

            if (bus_fd < 0) return; // disconnected: reconnect is the owner's job

            var pfds = [_]posix.pollfd{
                .{ .fd = bus_fd, .events = @intCast(@max(bus_events, 0)), .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&pfds, timeoutMs(timeout_usec)) catch return;
            if (pfds[1].revents & posix.POLL.IN != 0) {
                var buf: [8]u8 = undefined;
                _ = linux.read(self.wake_fd, &buf, 8); // drain the eventfd
            }
        }
    }

    fn kick(self: *Bus) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, @ptrCast(&one), 8);
    }

    /// sd_bus_get_timeout returns an ABSOLUTE CLOCK_MONOTONIC usec deadline
    /// (or u64-max for "none"); poll wants a relative ms timeout.
    fn timeoutMs(abs_usec: u64) i32 {
        if (abs_usec == std.math.maxInt(u64)) return -1;
        var ts: linux.timespec = undefined;
        if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 1000;
        const now_usec: u64 = @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
        if (abs_usec <= now_usec) return 0;
        const rel_ms = (abs_usec - now_usec) / 1000;
        return @intCast(@min(rel_ms, std.math.maxInt(i32)));
    }

    // ---- external (any-thread) call interface ------------------------------

    /// Synchronous method call. Marshals `args` (s/b/u/a{sv}), waits for
    /// the reply, returns it positioned at the first reply field. On
    /// CallFailed the D-Bus error name is available via lastDbusError().
    pub fn callMethod(
        self: *Bus,
        destination: [:0]const u8,
        path: [:0]const u8,
        interface: [:0]const u8,
        member: [:0]const u8,
        args: []const Arg,
    ) Error!Message {
        self.mu.lock();
        defer self.mu.unlock();
        defer self.kick();

        var m: ?*c.sd_bus_message = null;
        if (c.sd_bus_message_new_method_call(self.bus, &m, destination, path, interface, member) < 0)
            return error.Disconnected;
        defer _ = c.sd_bus_message_unref(m);
        try appendArgs(m.?, args);

        var err: c.sd_bus_error = .{ .name = null, .message = null, ._need_free = 0 };
        defer c.sd_bus_error_free(&err);
        var reply: ?*c.sd_bus_message = null;
        const r = c.sd_bus_call(self.bus, m, 0, &err, &reply);
        if (r < 0) {
            self.storeDbusError(&err);
            return switch (errnoFromRet(r)) {
                @intFromEnum(linux.E.NOTCONN), @intFromEnum(linux.E.CONNRESET) => error.Disconnected,
                else => error.CallFailed,
            };
        }
        return .{ .m = reply.?, .owned = true };
    }

    /// GetProperty returning the message positioned INSIDE the variant, at
    /// a value of signature `sig` (e.g. "s", "u", "(isi)").
    pub fn getProperty(
        self: *Bus,
        destination: [:0]const u8,
        path: [:0]const u8,
        interface: [:0]const u8,
        member: [:0]const u8,
        sig: [:0]const u8,
    ) Error!Message {
        self.mu.lock();
        defer self.mu.unlock();
        defer self.kick();

        var err: c.sd_bus_error = .{ .name = null, .message = null, ._need_free = 0 };
        defer c.sd_bus_error_free(&err);
        var reply: ?*c.sd_bus_message = null;
        const r = c.sd_bus_get_property(self.bus, destination, path, interface, member, &err, &reply, sig);
        if (r < 0) {
            self.storeDbusError(&err);
            return error.CallFailed;
        }
        return .{ .m = reply.?, .owned = true };
    }

    /// Convenience: string property, copied into `allocator`.
    pub fn getPropertyString(
        self: *Bus,
        allocator: std.mem.Allocator,
        destination: [:0]const u8,
        path: [:0]const u8,
        interface: [:0]const u8,
        member: [:0]const u8,
    ) Error![]u8 {
        var msg = try self.getProperty(destination, path, interface, member, "s");
        defer msg.deinit();
        const s = try msg.readString();
        return allocator.dupe(u8, s) catch error.OutOfMemory;
    }

    /// Convenience: u32 property.
    pub fn getPropertyU32(
        self: *Bus,
        destination: [:0]const u8,
        path: [:0]const u8,
        interface: [:0]const u8,
        member: [:0]const u8,
    ) Error!u32 {
        var msg = try self.getProperty(destination, path, interface, member, "u");
        defer msg.deinit();
        return msg.readU32();
    }

    /// Convenience: RAUC-style (isi) progress property; message string is
    /// copied into `allocator`.
    pub fn getPropertyProgress(
        self: *Bus,
        allocator: std.mem.Allocator,
        destination: [:0]const u8,
        path: [:0]const u8,
        interface: [:0]const u8,
        member: [:0]const u8,
    ) Error!Progress {
        var msg = try self.getProperty(destination, path, interface, member, "(isi)");
        defer msg.deinit();
        if (!try msg.enterContainer('r', "isi")) return error.InvalidReply;
        const percentage = try msg.readI32();
        const text = try msg.readString();
        const depth = try msg.readI32();
        try msg.exitContainer();
        const copy = allocator.dupeZ(u8, text) catch return error.OutOfMemory;
        return .{ .percentage = percentage, .message = copy, .depth = depth };
    }

    /// Install a signal match. `sender`/`path`/`interface`/`member` may be
    /// null to wildcard. The returned Match must be cancel()ed (or leaked
    /// deliberately for daemon-lifetime matches).
    pub fn matchSignal(
        self: *Bus,
        sender: ?[:0]const u8,
        path: ?[:0]const u8,
        interface: ?[:0]const u8,
        member: ?[:0]const u8,
        handler: SignalHandler,
        ctx: ?*anyopaque,
    ) Error!*Match {
        const tramp = self.gpa.create(Trampoline) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(tramp);
        tramp.* = .{ .handler = handler, .ctx = ctx };

        self.mu.lock();
        var slot: ?*c.sd_bus_slot = null;
        const r = c.sd_bus_match_signal(
            self.bus,
            &slot,
            if (sender) |s| s.ptr else null,
            if (path) |s| s.ptr else null,
            if (interface) |s| s.ptr else null,
            if (member) |s| s.ptr else null,
            signalTrampoline,
            tramp,
        );
        self.mu.unlock();
        self.kick();
        if (r < 0 or slot == null) return error.CallFailed;

        const match = self.gpa.create(Match) catch {
            self.mu.lock();
            _ = c.sd_bus_slot_unref(slot);
            self.mu.unlock();
            return error.OutOfMemory;
        };
        match.* = .{ .slot = slot.?, .bus = self, .trampoline = tramp };
        return match;
    }

    /// org.freedesktop.DBus.Properties.PropertiesChanged from `sender` at
    /// `path` — the shape RAUC progress/Operation tracking needs.
    pub fn matchPropertiesChanged(
        self: *Bus,
        sender: [:0]const u8,
        path: [:0]const u8,
        handler: SignalHandler,
        ctx: ?*anyopaque,
    ) Error!*Match {
        return self.matchSignal(
            sender,
            path,
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            handler,
            ctx,
        );
    }

    /// ObjectManager.GetManagedObjects on `destination` at `manager_path`
    /// ("/" for iwd), parsed into an owned ObjectTree.
    pub fn getManagedObjects(
        self: *Bus,
        gpa: std.mem.Allocator,
        destination: [:0]const u8,
        manager_path: [:0]const u8,
    ) Error!ObjectTree {
        var msg = try self.callMethod(destination, manager_path, object_manager_interface, "GetManagedObjects", &.{});
        defer msg.deinit();
        return msg.readManagedObjects(gpa);
    }

    /// Signal match with OBJECT-SUBTREE routing: like matchSignal, but
    /// matches every object under `path_namespace` (D-Bus match-rule
    /// path_namespace key) instead of one exact path. sd_bus_match_signal
    /// only takes exact paths, so this builds the rule string for
    /// sd_bus_add_match directly. Handlers route by Message.path().
    pub fn matchSignalPathNamespace(
        self: *Bus,
        sender: [:0]const u8,
        path_namespace: [:0]const u8,
        interface: [:0]const u8,
        member: [:0]const u8,
        handler: SignalHandler,
        ctx: ?*anyopaque,
    ) Error!*Match {
        var rule_buf: [512]u8 = undefined;
        const rule = std.fmt.bufPrintZ(
            &rule_buf,
            "type='signal',sender='{s}',path_namespace='{s}',interface='{s}',member='{s}'",
            .{ sender, path_namespace, interface, member },
        ) catch return error.InvalidArgs;

        const tramp = self.gpa.create(Trampoline) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(tramp);
        tramp.* = .{ .handler = handler, .ctx = ctx };

        self.mu.lock();
        var slot: ?*c.sd_bus_slot = null;
        const r = c.sd_bus_add_match(self.bus, &slot, rule.ptr, signalTrampoline, tramp);
        self.mu.unlock();
        self.kick();
        if (r < 0 or slot == null) return error.CallFailed;

        const match = self.gpa.create(Match) catch {
            self.mu.lock();
            _ = c.sd_bus_slot_unref(slot);
            self.mu.unlock();
            return error.OutOfMemory;
        };
        match.* = .{ .slot = slot.?, .bus = self, .trampoline = tramp };
        return match;
    }

    /// ObjectManager InterfacesAdded from `sender`'s manager at
    /// `manager_path` (iwd: "/"). Handler parses via readInterfacesAdded.
    pub fn matchInterfacesAdded(
        self: *Bus,
        sender: [:0]const u8,
        manager_path: [:0]const u8,
        handler: SignalHandler,
        ctx: ?*anyopaque,
    ) Error!*Match {
        return self.matchSignal(sender, manager_path, object_manager_interface, "InterfacesAdded", handler, ctx);
    }

    /// ObjectManager InterfacesRemoved (parse via readInterfacesRemoved).
    pub fn matchInterfacesRemoved(
        self: *Bus,
        sender: [:0]const u8,
        manager_path: [:0]const u8,
        handler: SignalHandler,
        ctx: ?*anyopaque,
    ) Error!*Match {
        return self.matchSignal(sender, manager_path, object_manager_interface, "InterfacesRemoved", handler, ctx);
    }

    /// PropertiesChanged for EVERY object under `path_namespace` (e.g.
    /// "/net/connman/iwd": Device/Station/Network state flips arrive on
    /// one match; route by Message.path(), parse via readPropertiesChanged).
    pub fn matchPropertiesChangedTree(
        self: *Bus,
        sender: [:0]const u8,
        path_namespace: [:0]const u8,
        handler: SignalHandler,
        ctx: ?*anyopaque,
    ) Error!*Match {
        return self.matchSignalPathNamespace(
            sender,
            path_namespace,
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            handler,
            ctx,
        );
    }

    fn storeDbusError(self: *Bus, err: *const c.sd_bus_error) void {
        self.last_error_len = 0;
        const name = err.name orelse return;
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
        const n = @min(span.len, self.last_error_buf.len);
        @memcpy(self.last_error_buf[0..n], span[0..n]);
        self.last_error_len = n;
    }

    /// D-Bus error name of the last failed call (e.g.
    /// "org.freedesktop.DBus.Error.AccessDenied"); empty if none. Copy it
    /// out before the next call from any thread.
    pub fn lastDbusError(self: *Bus) []const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.last_error_buf[0..self.last_error_len];
    }
};

// ---- marshaling (shared by callMethod and the offline tests) ----------------

fn appendArgs(m: *c.sd_bus_message, args: []const Arg) Error!void {
    for (args) |arg| switch (arg) {
        .s => |s| {
            if (c.sd_bus_message_append_basic(m, 's', s.ptr) < 0) return error.InvalidArgs;
        },
        .b => |b| {
            const v: c_int = @intFromBool(b);
            if (c.sd_bus_message_append_basic(m, 'b', &v) < 0) return error.InvalidArgs;
        },
        .u => |u| {
            var v: u32 = u;
            if (c.sd_bus_message_append_basic(m, 'u', &v) < 0) return error.InvalidArgs;
        },
        .dict => |entries| {
            if (c.sd_bus_message_open_container(m, 'a', "{sv}") < 0) return error.InvalidArgs;
            for (entries) |entry| {
                if (c.sd_bus_message_open_container(m, 'e', "sv") < 0) return error.InvalidArgs;
                if (c.sd_bus_message_append_basic(m, 's', entry.key.ptr) < 0) return error.InvalidArgs;
                if (c.sd_bus_message_open_container(m, 'v', entry.value.signature()) < 0) return error.InvalidArgs;
                switch (entry.value) {
                    .s => |s| {
                        if (c.sd_bus_message_append_basic(m, 's', s.ptr) < 0) return error.InvalidArgs;
                    },
                    .b => |b| {
                        const v: c_int = @intFromBool(b);
                        if (c.sd_bus_message_append_basic(m, 'b', &v) < 0) return error.InvalidArgs;
                    },
                    .u => |u| {
                        var v: u32 = u;
                        if (c.sd_bus_message_append_basic(m, 'u', &v) < 0) return error.InvalidArgs;
                    },
                }
                if (c.sd_bus_message_close_container(m) < 0) return error.InvalidArgs; // v
                if (c.sd_bus_message_close_container(m) < 0) return error.InvalidArgs; // e
            }
            if (c.sd_bus_message_close_container(m) < 0) return error.InvalidArgs; // a
        },
    };
}

// ---- retry/backoff ----------------------------------------------------------

/// Exponential backoff schedule for reconnect loops. Pure state machine —
/// callers own the sleeping — so it is unit-testable without time.
pub const Backoff = struct {
    initial_ms: u64 = 100,
    max_ms: u64 = 10_000,
    current_ms: u64 = 0,

    /// Delay to wait before the next attempt (0 on the very first call:
    /// try immediately, then back off 100, 200, 400 ... capped).
    pub fn next(self: *Backoff) u64 {
        const delay = self.current_ms;
        self.current_ms = if (self.current_ms == 0)
            self.initial_ms
        else
            @min(self.current_ms * 2, self.max_ms);
        return delay;
    }

    pub fn reset(self: *Backoff) void {
        self.current_ms = 0;
    }
};

/// Connect with retries: sleeps per Backoff between attempts, up to
/// `max_attempts`. Returns the last error when every attempt failed.
pub fn connectSystemRetry(gpa: std.mem.Allocator, max_attempts: u32) Error!*Bus {
    var backoff: Backoff = .{};
    var attempt: u32 = 0;
    var last_err: Error = error.NoBusSocket;
    while (attempt < max_attempts) : (attempt += 1) {
        sync.sleepMs(backoff.next());
        return Bus.connectSystem(gpa) catch |err| {
            last_err = err;
            continue;
        };
    }
    return last_err;
}

// ---- tests ------------------------------------------------------------------

test "connectSystem fails cleanly without a bus socket" {
    // Guard: on a developer host with a real system bus (or an address
    // override) a live connection could succeed — skip rather than flake.
    if (std.c.getenv("DBUS_SYSTEM_BUS_ADDRESS") != null) return error.SkipZigTest;
    if (fsutil.pathExists(system_bus_socket)) return error.SkipZigTest;
    try std.testing.expectError(error.NoBusSocket, Bus.connectSystem(std.testing.allocator));
}

test "Backoff schedule: immediate first try, doubling, capped" {
    var b: Backoff = .{ .initial_ms = 100, .max_ms = 1000 };
    try std.testing.expectEqual(@as(u64, 0), b.next());
    try std.testing.expectEqual(@as(u64, 100), b.next());
    try std.testing.expectEqual(@as(u64, 200), b.next());
    try std.testing.expectEqual(@as(u64, 400), b.next());
    try std.testing.expectEqual(@as(u64, 800), b.next());
    try std.testing.expectEqual(@as(u64, 1000), b.next());
    try std.testing.expectEqual(@as(u64, 1000), b.next());
    b.reset();
    try std.testing.expectEqual(@as(u64, 0), b.next());
}

// A socketpair-backed bus that is never actually connected to a daemon:
// sd_bus_set_fd + sd_bus_start moves the state machine out of UNSET so
// messages can be created, appended, sealed, rewound, and read — the whole
// marshaling layer is exercised offline. The peer fd must stay open (the
// start() auth bytes are written into it) and is closed by the caller.
const TestBus = struct { sd: *c.sd_bus, peer: posix.fd_t };

fn testBus() !TestBus {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS)
        return error.SkipZigTest;
    errdefer _ = linux.close(fds[1]);
    var sd: ?*c.sd_bus = null;
    if (c.sd_bus_new(&sd) < 0) return error.SkipZigTest;
    errdefer _ = c.sd_bus_unref(sd);
    if (c.sd_bus_set_fd(sd, fds[0], fds[0]) < 0) return error.SkipZigTest;
    if (c.sd_bus_start(sd) < 0) return error.SkipZigTest;
    return .{ .sd = sd.?, .peer = fds[1] };
}

test "marshal s/b/u and a{sv}: signature and round-trip read-back" {
    const tb = try testBus();
    defer _ = linux.close(tb.peer);
    const sd = tb.sd;
    // close (NOT flush_close): flushing waits for the auth handshake that
    // this deliberately-dead socketpair will never complete (90 s timeout).
    defer {
        c.sd_bus_close(sd);
        _ = c.sd_bus_unref(sd);
    }

    var m: ?*c.sd_bus_message = null;
    try std.testing.expect(c.sd_bus_message_new_method_call(
        sd,
        &m,
        "de.pengutronix.rauc",
        "/",
        "de.pengutronix.rauc.Installer",
        "InstallBundle",
    ) >= 0);
    defer _ = c.sd_bus_message_unref(m);

    try appendArgs(m.?, &.{
        .{ .s = "/data/.astro/staging/update.raucb" },
        .{ .dict = &.{
            .{ .key = "ignore-compatible", .value = .{ .b = true } },
            .{ .key = "tls-no-verify", .value = .{ .s = "no" } },
            .{ .key = "retries", .value = .{ .u = 3 } },
        } },
        .{ .b = false },
        .{ .u = 42 },
    });

    // Seal freezes the body; rewind positions the read cursor at the start.
    try std.testing.expect(c.sd_bus_message_seal(m, 1, 0) >= 0);
    try std.testing.expect(c.sd_bus_message_rewind(m, 1) > 0);

    var msg: Message = .{ .m = m.?, .owned = false };
    try std.testing.expectEqualStrings("sa{sv}bu", msg.signature());
    try std.testing.expectEqualStrings("/data/.astro/staging/update.raucb", try msg.readString());

    // a{sv} read-back through the typed container API.
    try std.testing.expect(try msg.enterContainer('a', "{sv}"));
    try std.testing.expect(try msg.enterContainer('e', "sv"));
    try std.testing.expectEqualStrings("ignore-compatible", try msg.readString());
    try std.testing.expect(try msg.enterContainer('v', "b"));
    try std.testing.expectEqual(true, try msg.readBool());
    try msg.exitContainer();
    try msg.exitContainer();
    try std.testing.expect(try msg.enterContainer('e', "sv"));
    try std.testing.expectEqualStrings("tls-no-verify", try msg.readString());
    try msg.skip("v"); // skipping an uninteresting value must also work
    try msg.exitContainer();
    try std.testing.expect(try msg.enterContainer('e', "sv"));
    try std.testing.expectEqualStrings("retries", try msg.readString());
    try std.testing.expect(try msg.enterContainer('v', "u"));
    try std.testing.expectEqual(@as(u32, 3), try msg.readU32());
    try msg.exitContainer();
    try msg.exitContainer();
    try std.testing.expect(!try msg.enterContainer('e', "sv")); // array exhausted
    try msg.exitContainer();

    try std.testing.expectEqual(false, try msg.readBool());
    try std.testing.expectEqual(@as(u32, 42), try msg.readU32());
    try std.testing.expectEqual(@as(?u8, null), try msg.peekType()); // fully consumed
}

test "marshal (isi)-shaped struct read-back (RAUC Progress shape)" {
    const tb = try testBus();
    defer _ = linux.close(tb.peer);
    const sd = tb.sd;
    // See the marshal test above for why this is close, not flush_close.
    defer {
        c.sd_bus_close(sd);
        _ = c.sd_bus_unref(sd);
    }

    var m: ?*c.sd_bus_message = null;
    try std.testing.expect(c.sd_bus_message_new_method_call(sd, &m, "a.b", "/", "a.b.C", "M") >= 0);
    defer _ = c.sd_bus_message_unref(m);

    try std.testing.expect(c.sd_bus_message_open_container(m, 'r', "isi") >= 0);
    var pct: i32 = 55;
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'i', &pct) >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "Copying image") >= 0);
    var depth: i32 = 2;
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'i', &depth) >= 0);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0);
    try std.testing.expect(c.sd_bus_message_seal(m, 1, 0) >= 0);
    try std.testing.expect(c.sd_bus_message_rewind(m, 1) > 0);

    var msg: Message = .{ .m = m.?, .owned = false };
    try std.testing.expect(try msg.enterContainer('r', "isi"));
    try std.testing.expectEqual(@as(i32, 55), try msg.readI32());
    try std.testing.expectEqualStrings("Copying image", try msg.readString());
    try std.testing.expectEqual(@as(i32, 2), try msg.readI32());
    try msg.exitContainer();
}

// ---- ObjectManager marshaling tests (offline, socketpair rig) --------------
// The builders below construct exactly the container nesting iwd's bundled
// ell emits (iwd-3.12 ell/dbus-service.c): a{oa{sa{sv}}} for
// GetManagedObjects, oa{sa{sv}} for InterfacesAdded, oas for
// InterfacesRemoved — so the readers are tested against the real shapes,
// not assumptions (the phase-2 GVariantDict lesson).

fn appendVariantString(m: *c.sd_bus_message, v: [:0]const u8) !void {
    try std.testing.expect(c.sd_bus_message_open_container(m, 'v', "s") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', v.ptr) >= 0);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0);
}

fn appendPropEntry(m: *c.sd_bus_message, key: [:0]const u8, open_variant_sig: [*:0]const u8) !void {
    try std.testing.expect(c.sd_bus_message_open_container(m, 'e', "sv") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', key.ptr) >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'v', open_variant_sig) >= 0);
}

fn closePropEntry(m: *c.sd_bus_message) !void {
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // v
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // e
}

/// Append one iwd-shaped interface entry (sa{sv}) with mixed prop types.
fn appendIwdDeviceInterface(m: *c.sd_bus_message) !void {
    try std.testing.expect(c.sd_bus_message_open_container(m, 'e', "sa{sv}") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "net.connman.iwd.Device") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "{sv}") >= 0);

    try appendPropEntry(m, "Name", "s");
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "wlan0") >= 0);
    try closePropEntry(m);

    try appendPropEntry(m, "Powered", "b");
    var powered: c_int = 1;
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'b', &powered) >= 0);
    try closePropEntry(m);

    try appendPropEntry(m, "Adapter", "o");
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'o', "/net/connman/iwd/0") >= 0);
    try closePropEntry(m);

    // A container-valued variant the reader must SKIP as .unsupported
    // without losing its place in the surrounding dict.
    try appendPropEntry(m, "Extensions", "as");
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "s") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "x1") >= 0);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0);
    try closePropEntry(m);

    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // a{sv}
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // e
}

fn appendIwdStationInterface(m: *c.sd_bus_message) !void {
    try std.testing.expect(c.sd_bus_message_open_container(m, 'e', "sa{sv}") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "net.connman.iwd.Station") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "{sv}") >= 0);

    try appendPropEntry(m, "State", "s");
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "connected") >= 0);
    try closePropEntry(m);

    try appendPropEntry(m, "ConnectedNetwork", "o");
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'o', "/net/connman/iwd/0/3/1234_psk") >= 0);
    try closePropEntry(m);

    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // a{sv}
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // e
}

test "readManagedObjects parses an iwd-shaped a{oa{sa{sv}}} tree" {
    const tb = try testBus();
    defer _ = linux.close(tb.peer);
    const sd = tb.sd;
    defer {
        c.sd_bus_close(sd);
        _ = c.sd_bus_unref(sd);
    }

    var m: ?*c.sd_bus_message = null;
    try std.testing.expect(c.sd_bus_message_new_method_call(
        sd,
        &m,
        "net.connman.iwd",
        "/",
        object_manager_interface,
        "GetManagedObjects",
    ) >= 0);
    defer _ = c.sd_bus_message_unref(m);

    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "{oa{sa{sv}}}") >= 0);

    // Object 1: a device with two interfaces.
    try std.testing.expect(c.sd_bus_message_open_container(m, 'e', "oa{sa{sv}}") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'o', "/net/connman/iwd/0/3") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "{sa{sv}}") >= 0);
    try appendIwdDeviceInterface(m.?);
    try appendIwdStationInterface(m.?);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // a{sa{sv}}
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // e

    // Object 2: a network with an interface holding a signed strength (n).
    try std.testing.expect(c.sd_bus_message_open_container(m, 'e', "oa{sa{sv}}") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'o', "/net/connman/iwd/0/3/1234_psk") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "{sa{sv}}") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'e', "sa{sv}") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "net.connman.iwd.Network") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "{sv}") >= 0);
    try appendPropEntry(m.?, "Name", "s");
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "astro-test") >= 0);
    try closePropEntry(m.?);
    try appendPropEntry(m.?, "Connected", "b");
    var connected: c_int = 0;
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'b', &connected) >= 0);
    try closePropEntry(m.?);
    try appendPropEntry(m.?, "SignalStrength", "n");
    var strength: i16 = -4900;
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'n', &strength) >= 0);
    try closePropEntry(m.?);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // a{sv}
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // e (iface)
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // a{sa{sv}}
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // e (object)

    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // outer a
    try std.testing.expect(c.sd_bus_message_seal(m, 1, 0) >= 0);
    try std.testing.expect(c.sd_bus_message_rewind(m, 1) > 0);

    var msg: Message = .{ .m = m.?, .owned = false };
    try std.testing.expectEqualStrings("a{oa{sa{sv}}}", msg.signature());

    var tree = try msg.readManagedObjects(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 2), tree.objects.len);
    try std.testing.expectEqualStrings("/net/connman/iwd/0/3", tree.objects[0].path);
    try std.testing.expectEqual(@as(usize, 2), tree.objects[0].interfaces.len);

    const dev = tree.find("/net/connman/iwd/0/3", "net.connman.iwd.Device").?;
    try std.testing.expectEqualStrings("wlan0", dev.get("Name").?.s);
    try std.testing.expectEqual(true, dev.get("Powered").?.b);
    try std.testing.expectEqualStrings("/net/connman/iwd/0", dev.get("Adapter").?.o);
    // The container-valued variant was skipped, signature retained, and
    // parsing continued cleanly past it.
    try std.testing.expectEqualStrings("as", dev.get("Extensions").?.unsupported);

    const sta = tree.find("/net/connman/iwd/0/3", "net.connman.iwd.Station").?;
    try std.testing.expectEqualStrings("connected", sta.get("State").?.s);
    try std.testing.expectEqualStrings("/net/connman/iwd/0/3/1234_psk", sta.get("ConnectedNetwork").?.o);

    const net = tree.find("/net/connman/iwd/0/3/1234_psk", "net.connman.iwd.Network").?;
    try std.testing.expectEqualStrings("astro-test", net.get("Name").?.s);
    try std.testing.expectEqual(false, net.get("Connected").?.b);
    try std.testing.expectEqual(@as(i16, -4900), net.get("SignalStrength").?.n);

    // Misses answer null, not garbage.
    try std.testing.expect(tree.find("/net/connman/iwd/0/3", "net.connman.iwd.AccessPoint") == null);
    try std.testing.expect(tree.find("/no/such/object", "net.connman.iwd.Device") == null);
    try std.testing.expect(dev.get("NoSuchProp") == null);
}

test "readInterfacesAdded / readInterfacesRemoved parse the ObjectManager signal bodies" {
    const tb = try testBus();
    defer _ = linux.close(tb.peer);
    const sd = tb.sd;
    defer {
        c.sd_bus_close(sd);
        _ = c.sd_bus_unref(sd);
    }

    // InterfacesAdded: oa{sa{sv}}.
    var m: ?*c.sd_bus_message = null;
    try std.testing.expect(c.sd_bus_message_new_method_call(sd, &m, "a.b", "/", "a.b.C", "M") >= 0);
    defer _ = c.sd_bus_message_unref(m);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'o', "/net/connman/iwd/0/4") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "{sa{sv}}") >= 0);
    try appendIwdDeviceInterface(m.?);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0);
    try std.testing.expect(c.sd_bus_message_seal(m, 1, 0) >= 0);
    try std.testing.expect(c.sd_bus_message_rewind(m, 1) > 0);

    var added_msg: Message = .{ .m = m.?, .owned = false };
    try std.testing.expectEqualStrings("oa{sa{sv}}", added_msg.signature());
    var added = try added_msg.readInterfacesAdded(std.testing.allocator);
    defer added.deinit();
    try std.testing.expectEqual(@as(usize, 1), added.objects.len);
    try std.testing.expectEqualStrings("/net/connman/iwd/0/4", added.objects[0].path);
    try std.testing.expectEqualStrings("wlan0", added.find("/net/connman/iwd/0/4", "net.connman.iwd.Device").?.get("Name").?.s);

    // InterfacesRemoved: oas.
    var m2: ?*c.sd_bus_message = null;
    try std.testing.expect(c.sd_bus_message_new_method_call(sd, &m2, "a.b", "/", "a.b.C", "M") >= 0);
    defer _ = c.sd_bus_message_unref(m2);
    try std.testing.expect(c.sd_bus_message_append_basic(m2, 'o', "/net/connman/iwd/0/4") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m2, 'a', "s") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m2, 's', "net.connman.iwd.Station") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m2, 's', "net.connman.iwd.Device") >= 0);
    try std.testing.expect(c.sd_bus_message_close_container(m2) >= 0);
    try std.testing.expect(c.sd_bus_message_seal(m2, 1, 0) >= 0);
    try std.testing.expect(c.sd_bus_message_rewind(m2, 1) > 0);

    var removed_msg: Message = .{ .m = m2.?, .owned = false };
    try std.testing.expectEqualStrings("oas", removed_msg.signature());
    var removed = try removed_msg.readInterfacesRemoved(std.testing.allocator);
    defer removed.deinit();
    try std.testing.expectEqualStrings("/net/connman/iwd/0/4", removed.path);
    try std.testing.expectEqual(@as(usize, 2), removed.interfaces.len);
    try std.testing.expectEqualStrings("net.connman.iwd.Station", removed.interfaces[0]);
    try std.testing.expectEqualStrings("net.connman.iwd.Device", removed.interfaces[1]);
}

test "readPropertiesChanged parses sa{sv}as including empty invalidated" {
    const tb = try testBus();
    defer _ = linux.close(tb.peer);
    const sd = tb.sd;
    defer {
        c.sd_bus_close(sd);
        _ = c.sd_bus_unref(sd);
    }

    var m: ?*c.sd_bus_message = null;
    try std.testing.expect(c.sd_bus_message_new_method_call(sd, &m, "a.b", "/", "a.b.C", "M") >= 0);
    defer _ = c.sd_bus_message_unref(m);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "net.connman.iwd.Station") >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "{sv}") >= 0);
    try appendPropEntry(m.?, "State", "s");
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "roaming") >= 0);
    try closePropEntry(m.?);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "s") >= 0);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0); // empty invalidated
    try std.testing.expect(c.sd_bus_message_seal(m, 1, 0) >= 0);
    try std.testing.expect(c.sd_bus_message_rewind(m, 1) > 0);

    var msg: Message = .{ .m = m.?, .owned = false };
    try std.testing.expectEqualStrings("sa{sv}as", msg.signature());
    var update = try msg.readPropertiesChanged(std.testing.allocator);
    defer update.deinit();
    try std.testing.expectEqualStrings("net.connman.iwd.Station", update.interface);
    try std.testing.expectEqual(@as(usize, 1), update.changed.len);
    try std.testing.expectEqualStrings("State", update.changed[0].name);
    try std.testing.expectEqualStrings("roaming", update.changed[0].value.s);
    try std.testing.expectEqual(@as(usize, 0), update.invalidated.len);
}

test "skipRestAndExit abandons a partially read container cleanly" {
    const tb = try testBus();
    defer _ = linux.close(tb.peer);
    const sd = tb.sd;
    defer {
        c.sd_bus_close(sd);
        _ = c.sd_bus_unref(sd);
    }

    var m: ?*c.sd_bus_message = null;
    try std.testing.expect(c.sd_bus_message_new_method_call(sd, &m, "a.b", "/", "a.b.C", "M") >= 0);
    defer _ = c.sd_bus_message_unref(m);
    try std.testing.expect(c.sd_bus_message_open_container(m, 'a', "s") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "one") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "two") >= 0);
    try std.testing.expect(c.sd_bus_message_append_basic(m, 's', "three") >= 0);
    try std.testing.expect(c.sd_bus_message_close_container(m) >= 0);
    var after: u32 = 7;
    try std.testing.expect(c.sd_bus_message_append_basic(m, 'u', &after) >= 0);
    try std.testing.expect(c.sd_bus_message_seal(m, 1, 0) >= 0);
    try std.testing.expect(c.sd_bus_message_rewind(m, 1) > 0);

    var msg: Message = .{ .m = m.?, .owned = false };
    try std.testing.expect(try msg.enterContainer('a', "s"));
    try std.testing.expectEqualStrings("one", try msg.readString());
    try msg.skipRestAndExit();
    // The cursor lands exactly past the array: the next value reads clean.
    try std.testing.expectEqual(@as(u32, 7), try msg.readU32());
}

test "live system bus (manual only)" {
    // Requires a running dbus-daemon; exercised by the phase-3 QEMU api
    // rig. Left compiled so the call surface cannot rot.
    if (true) return error.SkipZigTest;
    var bus = try Bus.connectSystem(std.testing.allocator);
    defer bus.deinit();
    try bus.start();
    var msg = try bus.callMethod(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "ListNames",
        &.{},
    );
    msg.deinit();
}
