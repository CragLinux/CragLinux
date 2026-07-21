//! Event bus: fixed ring buffer + SSE fan-out (docs/06 §2, §4, §7).
//!
//! Design (stage 2, implemented):
//!  - Ring: fixed capacity (ring_capacity = 1024) of (id, type, payload);
//!    ids are monotonically increasing u64 starting at 1, never reused;
//!    old events are overwritten silently. Last-Event-ID replay from
//!    before the ring's oldest retained id starts at the oldest retained
//!    event (silent clamp — the reconnecting client asked for history the
//!    ring no longer has).
//!  - publish() is callable from ANY thread (HTTP handler threads, the
//!    bus thread's signal callbacks) — internally mutex-protected, never
//!    blocks on slow consumers. Copies its inputs; callers may free
//!    theirs immediately.
//!  - Subscribers do not get private queues: each holds a cursor into the
//!    shared ring and copies events out under the bus mutex, so a slow
//!    SSE client can never make publish() block or the ring grow. A LIVE
//!    subscriber that the ring laps (cursor falls behind the oldest
//!    retained id) gets error.Overflowed from next() ONCE — the SSE
//!    writer emits an `event: overflow` marker frame and the subscription
//!    CONTINUES from the ring head (docs/06 §7 backpressure: the client
//!    is told about the gap, not dropped).
//!  - SSE clients: capped at max_subscribers (16); subscribe() fails with
//!    TooManySubscribers beyond that (HTTP layer maps it to 503
//!    urn:astro:problem:overloaded).
//!  - Wakeups: one pthread condvar (broadcast on publish). Zero-init
//!    pthread_cond_t IS musl's PTHREAD_COND_INITIALIZER, same rationale
//!    as sync.zig. musl condvars wait on CLOCK_REALTIME by default, so
//!    the timedwait deadline is computed on that clock.
//!
//! Event taxonomy (docs/06 §4) — payloads published through
//! publishEnvelope() carry the envelope
//!     {"type": <type>, "id": <event id>, "ts": <CLOCK_REALTIME seconds>,
//!      "operation": "op-<n>"?, "data": <event-specific JSON>}
//! where "operation" is present only for events tied to an operations-
//! registry entry (ops.zig ids). The types:
//!  - update.progress   {percentage, message, depth}  (RAUC Progress)
//!  - update.completed  {slot?, version?}
//!  - update.failed     {detail}
//!  - operation.state   {state, progress, message}    (registry change)
//!  - system.provisioned — RESERVED for the provisioning flow (phase 4);
//!    named now so the constant is pinned before any publisher exists.

const std = @import("std");
const sync = @import("sync.zig");

pub const ring_capacity = 1024;
pub const max_subscribers = 16;

/// Dotted event-type constants (docs/06 §4). Use these, never string
/// literals, so a typo is a compile error at the publish site.
pub const types = struct {
    pub const update_progress = "update.progress";
    pub const update_completed = "update.completed";
    pub const update_failed = "update.failed";
    /// Reserved for phase 4 (provisioning); no publisher yet.
    pub const system_provisioned = "system.provisioned";
    pub const operation_state = "operation.state";

    pub const network_wifi_state = "network.wifi.state";
    pub const network_wifi_scan_done = "network.wifi.scan.done";
    pub const network_ethernet_state = "network.ethernet.state";
};

/// Wire shape (SSE): `id: <id>\nevent: <event_type>\ndata: <payload>\n\n`.
pub const Event = struct {
    /// Monotonic, 1-based; doubles as the SSE id for Last-Event-ID replay.
    id: u64,
    /// Dotted type, e.g. "update.progress" (see `types`).
    event_type: []const u8,
    /// JSON document. When returned by Subscription.next() this is a
    /// subscription-owned copy, valid until the following next()/cancel().
    payload: []const u8,
};

pub const PublishError = error{OutOfMemory};
pub const SubscribeError = error{ TooManySubscribers, OutOfMemory };

/// One retained ring entry; event_type/payload are bus-owned copies.
const Slot = struct {
    id: u64,
    event_type: []u8,
    payload: []u8,
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    mu: sync.Mutex = .{},
    /// Broadcast on every publish; subscribers timed-wait on it.
    cond: std.c.pthread_cond_t = .{},
    /// Next id to assign (ids start at 1).
    next_id: u64 = 1,
    /// Number of retained events (== populated slots), <= ring_capacity.
    /// Oldest retained id is always next_id - count.
    count: usize = 0,
    /// Ring storage; the slot for id N lives at (N-1) % ring_capacity.
    slots: [ring_capacity]?Slot = @splat(null),
    /// Registry: enforces the cap and lets deinit() reclaim stragglers.
    subs: [max_subscribers]?*Subscription = @splat(null),

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{ .allocator = allocator };
    }

    /// All subscriptions must be quiescent (their connection threads
    /// joined or gone) before teardown; any still registered are freed.
    pub fn deinit(self: *EventBus) void {
        for (self.subs) |maybe_sub| if (maybe_sub) |sub| {
            sub.freeScratch();
            self.allocator.destroy(sub);
        };
        for (self.slots) |maybe_slot| if (maybe_slot) |slot| {
            self.allocator.free(slot.event_type);
            self.allocator.free(slot.payload);
        };
        self.* = undefined;
    }

    /// Copy (event_type, json_payload) into the ring, assign the next id,
    /// wake subscribers. Thread-safe, never blocks on consumers. Returns
    /// the assigned id. On OutOfMemory no id is consumed.
    pub fn publish(self: *EventBus, event_type: []const u8, json_payload: []const u8) PublishError!u64 {
        self.mu.lock();
        defer self.mu.unlock();
        const t = try self.allocator.dupe(u8, event_type);
        errdefer self.allocator.free(t);
        const p = try self.allocator.dupe(u8, json_payload);
        return self.commitLocked(t, p);
    }

    /// Publish with the docs/06 §4 envelope wrapped around `data_json`
    /// (which must be a complete JSON value): the assigned event id and a
    /// CLOCK_REALTIME seconds timestamp are stamped in, plus the
    /// operation id when given. `operation` must be a plain ops.zig id
    /// ("op-<n>") — it is interpolated into JSON unescaped.
    pub fn publishEnvelope(self: *EventBus, event_type: []const u8, operation: ?[]const u8, data_json: []const u8) PublishError!u64 {
        self.mu.lock();
        defer self.mu.unlock();
        const id = self.next_id;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const payload = if (operation) |op|
            try std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\",\"id\":{d},\"ts\":{d},\"operation\":\"{s}\",\"data\":{s}}}", .{ event_type, id, ts.sec, op, data_json })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\",\"id\":{d},\"ts\":{d},\"data\":{s}}}", .{ event_type, id, ts.sec, data_json });
        errdefer self.allocator.free(payload);
        const t = try self.allocator.dupe(u8, event_type);
        return self.commitLocked(t, payload);
    }

    /// Takes ownership of both copies; cannot fail. Caller holds mu.
    fn commitLocked(self: *EventBus, event_type: []u8, payload: []u8) u64 {
        const id = self.next_id;
        const idx: usize = @intCast((id - 1) % ring_capacity);
        if (self.slots[idx]) |old| {
            self.allocator.free(old.event_type);
            self.allocator.free(old.payload);
        }
        self.slots[idx] = .{ .id = id, .event_type = event_type, .payload = payload };
        self.next_id += 1;
        if (self.count < ring_capacity) self.count += 1;
        _ = std.c.pthread_cond_broadcast(&self.cond);
        return id;
    }

    /// Register an SSE consumer. `last_event_id` (from the Last-Event-ID
    /// request header) replays retained events with id > last_event_id
    /// before live delivery; null starts live-only. An id older than the
    /// ring retains starts at the oldest retained event; an id at or past
    /// the newest (e.g. from a previous daemon run — ids restart at 1)
    /// starts live. Fails with TooManySubscribers beyond max_subscribers
    /// (the HTTP layer maps this to a 503 problem).
    pub fn subscribe(self: *EventBus, last_event_id: ?u64) SubscribeError!*Subscription {
        self.mu.lock();
        defer self.mu.unlock();
        const slot: *?*Subscription = for (&self.subs) |*s| {
            if (s.* == null) break s;
        } else return error.TooManySubscribers;
        const sub = try self.allocator.create(Subscription);
        const oldest = self.next_id - self.count;
        sub.* = .{
            .bus = self,
            .cursor = if (last_event_id) |lid|
                @min(@max(lid +| 1, oldest), self.next_id)
            else
                self.next_id,
        };
        slot.* = sub;
        return sub;
    }
};

/// One SSE consumer's view. The HTTP connection thread loops on next()
/// and writes frames (serveStream below); everything is owned by the bus
/// allocator and reclaimed by cancel().
pub const Subscription = struct {
    bus: *EventBus,
    /// Next event id to deliver.
    cursor: u64,
    /// Copies returned by the last next(); replaced on each call.
    scratch_type: []u8 = &.{},
    scratch_payload: []u8 = &.{},

    /// Block up to `timeout_ms` for the next event. Returns:
    ///  - an Event (a copy, borrowed until the following next()/cancel()),
    ///  - null on timeout (caller writes an SSE keepalive comment),
    ///  - error.Overflowed when the ring lapped this consumer — the
    ///    cursor has been snapped to the oldest retained event; the
    ///    caller writes the `event: overflow` marker frame and KEEPS
    ///    calling next() (delivery resumes from the ring head).
    /// Transient OutOfMemory while copying degrades to a keepalive tick
    /// (null) without advancing the cursor; the event is retried.
    pub fn next(self: *Subscription, timeout_ms: u64) error{Overflowed}!?Event {
        const bus = self.bus;
        self.freeScratch();

        // Deadline on CLOCK_REALTIME (musl condvar default). Clamped so
        // the isize casts below cannot overflow; nobody waits > 1 day.
        const wait_ms = @min(timeout_ms, std.time.ms_per_day);
        var deadline: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(.REALTIME, &deadline);
        const total_ns = @as(u64, @intCast(deadline.nsec)) + (wait_ms % 1000) * std.time.ns_per_ms;
        deadline.sec += @intCast(wait_ms / 1000 + total_ns / std.time.ns_per_s);
        deadline.nsec = @intCast(total_ns % std.time.ns_per_s);

        bus.mu.lock();
        while (true) {
            const oldest = bus.next_id - bus.count;
            if (self.cursor < oldest) {
                self.cursor = oldest;
                bus.mu.unlock();
                return error.Overflowed;
            }
            if (self.cursor < bus.next_id) {
                const slot = bus.slots[@intCast((self.cursor - 1) % ring_capacity)].?;
                std.debug.assert(slot.id == self.cursor);
                const t = bus.allocator.dupe(u8, slot.event_type) catch {
                    bus.mu.unlock();
                    return null;
                };
                const p = bus.allocator.dupe(u8, slot.payload) catch {
                    bus.allocator.free(t);
                    bus.mu.unlock();
                    return null;
                };
                self.scratch_type = t;
                self.scratch_payload = p;
                const id = slot.id;
                self.cursor += 1;
                bus.mu.unlock();
                return .{ .id = id, .event_type = t, .payload = p };
            }
            if (wait_ms == 0) {
                bus.mu.unlock();
                return null;
            }
            const rc = std.c.pthread_cond_timedwait(&bus.cond, &bus.mu.inner, &deadline);
            if (rc == .TIMEDOUT) {
                bus.mu.unlock();
                return null;
            }
            // SUCCESS or spurious wake: re-check under the still-held mutex.
        }
    }

    /// Deregister and free. Called when the client disconnects. The
    /// subscription pointer is invalid afterwards.
    pub fn cancel(self: *Subscription) void {
        const bus = self.bus;
        bus.mu.lock();
        for (&bus.subs) |*s| {
            if (s.* == self) s.* = null;
        }
        bus.mu.unlock();
        self.freeScratch();
        bus.allocator.destroy(self);
    }

    fn freeScratch(self: *Subscription) void {
        // Zero-length slices are the "nothing borrowed" state; Allocator
        // .free on len 0 is a documented no-op.
        self.bus.allocator.free(self.scratch_type);
        self.bus.allocator.free(self.scratch_payload);
        self.scratch_type = &.{};
        self.scratch_payload = &.{};
    }
};

// ---- SSE wire format --------------------------------------------------------

pub const sse_content_type = "text/event-stream";
/// Client reconnect hint (SSE `retry:` field), written once per stream.
pub const sse_retry_ms = 3000;
/// Heartbeat comment cadence: detects dead clients (the write fails once
/// the kernel buffer drains) without any event traffic.
pub const heartbeat_ms = 15_000;

pub const sse_prelude = std.fmt.comptimePrint("retry: {d}\n\n", .{sse_retry_ms});
/// Comment-only frame; clients ignore it, dead sockets fail the write.
pub const keepalive_frame = ": keepalive\n\n";
/// Gap marker (docs/06 §7): the ring lapped this client; delivery resumes
/// from the oldest retained event right after this frame.
pub const overflow_frame = "event: overflow\ndata: {\"reason\":\"subscriber lagged; resuming from oldest retained event\"}\n\n";

/// Serialize one event as an SSE frame: `id:` + `event:` lines, payload
/// split across `data:` lines on '\n' (SSE cannot carry raw newlines),
/// blank-line terminator. Caller frees.
pub fn formatFrame(allocator: std.mem.Allocator, ev: Event) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const head = try std.fmt.allocPrint(allocator, "id: {d}\nevent: {s}\n", .{ ev.id, ev.event_type });
    defer allocator.free(head);
    try out.appendSlice(allocator, head);
    var lines = std.mem.splitScalar(u8, ev.payload, '\n');
    while (lines.next()) |line| {
        try out.appendSlice(allocator, "data: ");
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// Parse an SSE Last-Event-ID header value; malformed or absent means
/// live-only (null), matching browser EventSource behavior of simply not
/// sending the header.
pub fn parseLastEventId(header: ?[]const u8) ?u64 {
    const v = std.mem.trim(u8, header orelse return null, " \t");
    return std.fmt.parseInt(u64, v, 10) catch null;
}

/// The SSE serve loop, run on the connection thread AFTER the HTTP layer
/// has written the response head (200, Content-Type: text/event-stream,
/// no Content-Length): prelude, then frames / keepalives / overflow
/// markers until a write fails (client gone) — the only exit. The caller
/// cancels the subscription afterwards. `writer` is anything with
/// `writeAll([]const u8) !void` (an fd wrapper in main.zig, a capture
/// buffer in tests).
pub fn serveStream(sub: *Subscription, writer: anytype) void {
    writer.writeAll(sse_prelude) catch return;
    while (true) {
        const maybe_ev = sub.next(heartbeat_ms) catch {
            writer.writeAll(overflow_frame) catch return;
            continue;
        };
        if (maybe_ev) |ev| {
            const frame = formatFrame(sub.bus.allocator, ev) catch return;
            defer sub.bus.allocator.free(frame);
            writer.writeAll(frame) catch return;
        } else {
            writer.writeAll(keepalive_frame) catch return;
        }
    }
}

// ---- tests ------------------------------------------------------------------

test "publish assigns monotonically increasing ids" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    const a = try bus.publish(types.update_progress, "{\"percentage\":10}");
    const b = try bus.publish(types.update_progress, "{\"percentage\":20}");
    try std.testing.expectEqual(@as(u64, 1), a);
    try std.testing.expect(b == a + 1);
}

test "ring wraparound: replay from id within and before the retained window" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    // Publish past capacity so the ring wraps; each payload is unique so
    // replay can prove content survives (and that publish copied it: the
    // scratch buffer is reused and mutated between publishes).
    var scratch: [32]u8 = undefined;
    const total = ring_capacity + 476; // ids 1..1500, retained 477..1500
    var i: u64 = 1;
    while (i <= total) : (i += 1) {
        const payload = try std.fmt.bufPrint(&scratch, "{{\"n\":{d}}}", .{i});
        _ = try bus.publish(types.operation_state, payload);
    }

    // Replay from inside the retained window: exactly the tail follows.
    {
        const sub = try bus.subscribe(total - 10);
        defer sub.cancel();
        var expect_id: u64 = total - 9;
        while (expect_id <= total) : (expect_id += 1) {
            const ev = (try sub.next(0)).?;
            try std.testing.expectEqual(expect_id, ev.id);
            try std.testing.expectEqualStrings(types.operation_state, ev.event_type);
            const want = try std.fmt.bufPrint(&scratch, "{{\"n\":{d}}}", .{expect_id});
            try std.testing.expectEqualStrings(want, ev.payload);
        }
        try std.testing.expectEqual(@as(?Event, null), try sub.next(0));
    }

    // Replay from before the window: silently clamped to oldest retained.
    {
        const sub = try bus.subscribe(10);
        defer sub.cancel();
        const ev = (try sub.next(0)).?;
        try std.testing.expectEqual(total - ring_capacity + 1, ev.id);
    }

    // Replay id at/past the newest (stale client from a previous run):
    // live-only, nothing retained is replayed.
    {
        const sub = try bus.subscribe(total + 500);
        defer sub.cancel();
        try std.testing.expectEqual(@as(?Event, null), try sub.next(0));
        const id = try bus.publish(types.update_completed, "{}");
        try std.testing.expectEqual(id, (try sub.next(0)).?.id);
    }
}

test "live subscriber lapped by the ring: overflow marker then continue from head" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const sub = try bus.subscribe(null); // live: cursor at next_id (1)
    defer sub.cancel();

    var i: u64 = 0;
    while (i < ring_capacity + 8) : (i += 1) _ = try bus.publish(types.update_progress, "{}");

    // Cursor 1 fell behind oldest retained (9): exactly one Overflowed...
    try std.testing.expectError(error.Overflowed, sub.next(0));
    // ...then delivery CONTINUES from the ring head, no drop.
    const ev = (try sub.next(0)).?;
    try std.testing.expectEqual(@as(u64, 9), ev.id);
    try std.testing.expectEqual(@as(u64, 10), (try sub.next(0)).?.id);
}

test "subscriber cap: 17th subscribe fails, freed slot is reusable" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    var subs: [max_subscribers]*Subscription = undefined;
    for (&subs) |*s| s.* = try bus.subscribe(null);
    try std.testing.expectError(error.TooManySubscribers, bus.subscribe(null));

    subs[5].cancel();
    const replacement = try bus.subscribe(null);
    subs[5] = replacement;
    try std.testing.expectError(error.TooManySubscribers, bus.subscribe(null));
    for (subs) |s| s.cancel();
}

test "publishEnvelope stamps type, id, ts, operation into the payload" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try bus.publishEnvelope(types.update_progress, "op-1", "{\"percentage\":42}");
    _ = try bus.publishEnvelope(types.update_failed, null, "{\"detail\":\"boom\"}");

    const sub = try bus.subscribe(0);
    defer sub.cancel();

    const first = (try sub.next(0)).?;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), first.payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(types.update_progress, parsed.value.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
    try std.testing.expect(parsed.value.object.get("ts").?.integer > 0);
    try std.testing.expectEqualStrings("op-1", parsed.value.object.get("operation").?.string);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("data").?.object.get("percentage").?.integer);

    const second = (try sub.next(0)).?;
    var parsed2 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), second.payload, .{});
    defer parsed2.deinit();
    try std.testing.expect(parsed2.value.object.get("operation") == null);
    try std.testing.expectEqualStrings("boom", parsed2.value.object.get("data").?.object.get("detail").?.string);
}

test "formatFrame: id/event/data lines, multi-line payload splitting" {
    const frame = try formatFrame(std.testing.allocator, .{
        .id = 7,
        .event_type = "update.progress",
        .payload = "{\"percentage\":30}",
    });
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("id: 7\nevent: update.progress\ndata: {\"percentage\":30}\n\n", frame);

    // Raw newlines cannot travel in one data field: one line each.
    const multi = try formatFrame(std.testing.allocator, .{ .id = 8, .event_type = "t", .payload = "a\nb" });
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualStrings("id: 8\nevent: t\ndata: a\ndata: b\n\n", multi);
}

test "parseLastEventId: numeric, padded, absent, garbage" {
    try std.testing.expectEqual(@as(?u64, 42), parseLastEventId("42"));
    try std.testing.expectEqual(@as(?u64, 42), parseLastEventId(" 42\t"));
    try std.testing.expectEqual(@as(?u64, null), parseLastEventId(null));
    try std.testing.expectEqual(@as(?u64, null), parseLastEventId("abc"));
    try std.testing.expectEqual(@as(?u64, null), parseLastEventId("-1"));
    try std.testing.expectEqual(@as(?u64, null), parseLastEventId(""));
}

/// Capture writer for serveStream tests: succeeds `remaining` times, then
/// fails like a closed socket (bounds the loop without timing games).
const ScriptWriter = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    remaining: usize,

    fn writeAll(self: *ScriptWriter, bytes: []const u8) !void {
        if (self.remaining == 0) return error.BrokenPipe;
        self.remaining -= 1;
        try self.buf.appendSlice(self.allocator, bytes);
    }

    fn deinit(self: *ScriptWriter) void {
        self.buf.deinit(self.allocator);
    }
};

test "serveStream: prelude then frames, exits on write failure" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    _ = try bus.publish(types.update_progress, "{\"percentage\":10}");
    _ = try bus.publish(types.update_completed, "{\"slot\":\"B\"}");
    _ = try bus.publish(types.operation_state, "{}");

    const sub = try bus.subscribe(0);
    defer sub.cancel();

    // prelude + two frames succeed; the third frame's write fails, which
    // must end the loop before it would block waiting for a heartbeat.
    var w: ScriptWriter = .{ .allocator = std.testing.allocator, .remaining = 3 };
    defer w.deinit();
    serveStream(sub, &w);

    const expected = sse_prelude ++
        "id: 1\nevent: update.progress\ndata: {\"percentage\":10}\n\n" ++
        "id: 2\nevent: update.completed\ndata: {\"slot\":\"B\"}\n\n";
    try std.testing.expectEqualStrings(expected, w.buf.items);
}

test "serveStream: lapped subscriber gets the overflow frame, then head" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    const sub = try bus.subscribe(null);
    defer sub.cancel();
    var i: u64 = 0;
    while (i < ring_capacity + 2) : (i += 1) _ = try bus.publish(types.update_progress, "{}");

    // prelude + overflow marker + first two head frames, then fail.
    var w: ScriptWriter = .{ .allocator = std.testing.allocator, .remaining = 4 };
    defer w.deinit();
    serveStream(sub, &w);

    const expected = sse_prelude ++ overflow_frame ++
        "id: 3\nevent: update.progress\ndata: {}\n\n" ++
        "id: 4\nevent: update.progress\ndata: {}\n\n";
    try std.testing.expectEqualStrings(expected, w.buf.items);
}

test "concurrency: two publishers, reader sees every id exactly once, in order" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    // 2 * 400 = 800 < ring_capacity: the ring retains everything, so the
    // reader must observe ids 1..800 consecutively regardless of how the
    // two publishers interleave.
    const per_thread = 400;
    const Publisher = struct {
        fn run(b: *EventBus) void {
            for (0..per_thread) |_| {
                _ = b.publish(types.operation_state, "{\"state\":\"running\"}") catch unreachable;
            }
        }
    };

    const sub = try bus.subscribe(0); // replay-from-start cursor
    defer sub.cancel();

    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Publisher.run, .{&bus});

    var expect_id: u64 = 1;
    while (expect_id <= 2 * per_thread) : (expect_id += 1) {
        const ev = (try sub.next(5000)) orelse break; // timeout = test failure below
        try std.testing.expectEqual(expect_id, ev.id);
    }
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 2 * per_thread + 1), expect_id);
    // Everything drained: an immediate poll finds nothing more.
    try std.testing.expectEqual(@as(?Event, null), try sub.next(0));
}
