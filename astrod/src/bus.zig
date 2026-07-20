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
    /// a{sv} whose key was not interesting).
    pub fn skip(self: *Message, types: [*:0]const u8) Error!void {
        if (c.sd_bus_message_skip(self.m, types) < 0) return error.InvalidReply;
    }

    pub fn signature(self: *Message) [:0]const u8 {
        const sig = c.sd_bus_message_get_signature(self.m, 1);
        if (sig == null) return "";
        return std.mem.span(@as([*:0]const u8, @ptrCast(sig)));
    }
};

/// RAUC's Progress property: (isi) = percentage, message, nesting depth
/// (source of truth: de.pengutronix.rauc.Installer.xml in the pinned
/// rauc-1.15.2 tree — note it is (isi), not the (iis) some docs claim).
pub const Progress = struct {
    percentage: i32,
    message: [:0]const u8,
    depth: i32,
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
