//! Operation registry: the async-work model of AD-013 (docs/06 §4).
//! POST endpoints that start long-running work return 202 +
//! {"operation": "/api/v1/operations/op-<n>"}; GET /operations[/{id}]
//! reads the registry; events carry the operation id.
//!
//! Contracts (per the phase-2 spine):
//!  - ids are "op-<n>", n monotonically increasing from 1 per daemon run
//!    (operations are in-memory; after a restart, re-attach discovers an
//!    in-flight RAUC install and REGISTERS A NEW operation for it —
//!    docs/06 §7 says the id stays *pollable*, which the store-recovery
//!    work handles; this registry itself is volatile).
//!  - all methods are thread-safe (HTTP handler threads + bus thread).
//!    None of them call out of the module while holding the lock, so the
//!    registry mutex is a LEAF lock: safe to take from bus-thread signal
//!    callbacks (which run with the bus mutex held).
//!  - the registry keeps every finished operation for the daemon's
//!    lifetime (bounded: max_operations, oldest finished evicted first).
//!  - id slices returned by create() are owned by the registry and remain
//!    valid until the record is evicted or the registry deinits; callers
//!    that hold an id across time (e.g. the update manager's current-op
//!    tracking) must copy it.

const std = @import("std");
const sync = @import("sync.zig");

pub const max_operations = 64;

/// The daemon-wide registry, set by main.zig at startup (same module-
/// global pattern as update.manager). Null only under unit tests — the
/// operations routes answer 501 then, so router tests need no fixture.
pub var global: ?*Registry = null;

pub const State = enum {
    pending,
    running,
    succeeded,
    failed,

    pub fn jsonName(self: State) []const u8 {
        return @tagName(self);
    }

    pub fn isFinished(self: State) bool {
        return self == .succeeded or self == .failed;
    }
};

pub const Kind = enum {
    update_install,
    wifi_scan, // phase 3
};

/// Snapshot of one operation, safe to serialize while the original keeps
/// mutating (strings are copies owned by the caller's allocator — see
/// freeOperation for non-arena callers).
pub const Operation = struct {
    /// "op-<n>".
    id: []const u8,
    kind: Kind,
    state: State,
    /// 0-100; only meaningful while running (RAUC progress percentage).
    progress: u8 = 0,
    /// Human-readable current step ("Copying image", ...).
    message: []const u8 = "",
    /// RFC 7807-ish detail when state == .failed.
    @"error": ?[]const u8 = null,
    /// Outcome summary when state == .succeeded (docs/06 §4: operations
    /// carry state/progress/error/result), e.g. the install's next step.
    result: ?[]const u8 = null,
};

/// Internal mutable record; all strings owned by the registry allocator.
const Record = struct {
    id: []u8,
    kind: Kind,
    state: State,
    progress: u8,
    message: []u8,
    err: ?[]u8,
    result: ?[]u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mu: sync.Mutex = .{},
    next_n: u64 = 1,
    records: std.ArrayList(Record) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.records.items) |*r| self.freeRecord(r);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    fn freeRecord(self: *Registry, r: *Record) void {
        self.allocator.free(r.id);
        self.allocator.free(r.message);
        if (r.err) |e| self.allocator.free(e);
        if (r.result) |res| self.allocator.free(res);
    }

    /// Allocate a new operation in state .pending; returns its id (owned
    /// by the registry — copy it if held long-term). Thread-safe.
    pub fn create(self: *Registry, kind: Kind) error{OutOfMemory}![]const u8 {
        self.mu.lock();
        defer self.mu.unlock();

        // Bounded storage: evict the oldest FINISHED record first; if every
        // record is still live (implausible: long-running work is
        // serialized per subsystem), evict the oldest regardless so the
        // bound holds.
        if (self.records.items.len >= max_operations) {
            const idx = for (self.records.items, 0..) |r, i| {
                if (r.state.isFinished()) break i;
            } else 0;
            var evicted = self.records.orderedRemove(idx);
            self.freeRecord(&evicted);
        }

        const id = try std.fmt.allocPrint(self.allocator, "op-{d}", .{self.next_n});
        errdefer self.allocator.free(id);
        const message = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(message);
        try self.records.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .state = .pending,
            .progress = 0,
            .message = message,
            .err = null,
            .result = null,
        });
        self.next_n += 1;
        return id;
    }

    fn findLocked(self: *Registry, id: []const u8) ?*Record {
        for (self.records.items) |*r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }

    /// Update state/progress/message of an operation (the bus thread calls
    /// this from RAUC progress signals). Unknown id is a programming error
    /// upstream and is ignored (logged) rather than crashing; an OOM while
    /// copying the message keeps the previous message.
    pub fn update(self: *Registry, id: []const u8, state: State, progress: u8, message: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const r = self.findLocked(id) orelse {
            std.log.debug("ops: update for unknown operation {s}", .{id});
            return;
        };
        r.state = state;
        r.progress = progress;
        if (self.allocator.dupe(u8, message)) |copy| {
            self.allocator.free(r.message);
            r.message = copy;
        } else |_| {}
    }

    /// Mark failed with an error detail (progress kept where it stopped).
    pub fn fail(self: *Registry, id: []const u8, detail: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const r = self.findLocked(id) orelse {
            std.log.debug("ops: fail for unknown operation {s}", .{id});
            return;
        };
        r.state = .failed;
        if (self.allocator.dupe(u8, detail)) |copy| {
            if (r.err) |old| self.allocator.free(old);
            r.err = copy;
        } else |_| {}
    }

    /// Mark succeeded (progress 100) with a result summary.
    pub fn succeed(self: *Registry, id: []const u8, result: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const r = self.findLocked(id) orelse {
            std.log.debug("ops: succeed for unknown operation {s}", .{id});
            return;
        };
        r.state = .succeeded;
        r.progress = 100;
        if (self.allocator.dupe(u8, result)) |copy| {
            if (r.result) |old| self.allocator.free(old);
            r.result = copy;
        } else |_| {}
    }

    fn snapshotLocked(self: *Registry, allocator: std.mem.Allocator, r: *const Record) error{OutOfMemory}!Operation {
        _ = self;
        const id = try allocator.dupe(u8, r.id);
        errdefer allocator.free(id);
        const message = try allocator.dupe(u8, r.message);
        errdefer allocator.free(message);
        const err = if (r.err) |e| try allocator.dupe(u8, e) else null;
        errdefer if (err) |e| allocator.free(e);
        const result = if (r.result) |res| try allocator.dupe(u8, res) else null;
        return .{
            .id = id,
            .kind = r.kind,
            .state = r.state,
            .progress = r.progress,
            .message = message,
            .@"error" = err,
            .result = result,
        };
    }

    /// Snapshot one operation by id (copied into `allocator`, caller
    /// frees — freeOperation); null when unknown (HTTP layer answers 404).
    pub fn get(self: *Registry, allocator: std.mem.Allocator, id: []const u8) error{OutOfMemory}!?Operation {
        self.mu.lock();
        defer self.mu.unlock();
        const r = self.findLocked(id) orelse return null;
        return try self.snapshotLocked(allocator, r);
    }

    /// Snapshot all operations, newest first (copied into `allocator`,
    /// caller frees — freeList).
    pub fn list(self: *Registry, allocator: std.mem.Allocator) error{OutOfMemory}![]Operation {
        self.mu.lock();
        defer self.mu.unlock();
        const out = try allocator.alloc(Operation, self.records.items.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |op| freeOperation(allocator, op);
            allocator.free(out);
        }
        while (built < out.len) : (built += 1) {
            // Newest first: records is append-ordered (oldest at 0).
            const r = &self.records.items[self.records.items.len - 1 - built];
            out[built] = try self.snapshotLocked(allocator, r);
        }
        return out;
    }
};

/// Free a snapshot returned by get()/list() (no-op cleanup for arenas).
pub fn freeOperation(allocator: std.mem.Allocator, op: Operation) void {
    allocator.free(op.id);
    allocator.free(op.message);
    if (op.@"error") |e| allocator.free(e);
    if (op.result) |r| allocator.free(r);
}

pub fn freeList(allocator: std.mem.Allocator, operations: []Operation) void {
    for (operations) |op| freeOperation(allocator, op);
    allocator.free(operations);
}

// ---- tests ------------------------------------------------------------------

test "registry: empty list, get of unknown id is null" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ops = try reg.list(std.testing.allocator);
    defer freeList(std.testing.allocator, ops);
    try std.testing.expectEqual(@as(usize, 0), ops.len);
    try std.testing.expectEqual(@as(?Operation, null), try reg.get(std.testing.allocator, "op-1"));
}

test "registry lifecycle: create -> update -> succeed, ids monotonic from 1" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const id1 = try reg.create(.update_install);
    try std.testing.expectEqualStrings("op-1", id1);
    const id2 = try reg.create(.wifi_scan);
    try std.testing.expectEqualStrings("op-2", id2);

    const created = (try reg.get(allocator, "op-1")).?;
    defer freeOperation(allocator, created);
    try std.testing.expectEqual(State.pending, created.state);
    try std.testing.expectEqual(Kind.update_install, created.kind);
    try std.testing.expectEqual(@as(u8, 0), created.progress);

    reg.update("op-1", .running, 42, "Copying image");
    const running = (try reg.get(allocator, "op-1")).?;
    defer freeOperation(allocator, running);
    try std.testing.expectEqual(State.running, running.state);
    try std.testing.expectEqual(@as(u8, 42), running.progress);
    try std.testing.expectEqualStrings("Copying image", running.message);
    try std.testing.expect(running.@"error" == null);

    reg.succeed("op-1", "installed; reboot to apply");
    const done = (try reg.get(allocator, "op-1")).?;
    defer freeOperation(allocator, done);
    try std.testing.expectEqual(State.succeeded, done.state);
    try std.testing.expectEqual(@as(u8, 100), done.progress);
    try std.testing.expectEqualStrings("installed; reboot to apply", done.result.?);
}

test "registry: fail keeps progress and sets error detail" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    const id = try reg.create(.update_install);
    reg.update(id, .running, 60, "Installing");
    reg.fail(id, "RAUC install failed (result 1)");
    const op = (try reg.get(allocator, id)).?;
    defer freeOperation(allocator, op);
    try std.testing.expectEqual(State.failed, op.state);
    try std.testing.expectEqual(@as(u8, 60), op.progress);
    try std.testing.expectEqualStrings("RAUC install failed (result 1)", op.@"error".?);
}

test "registry: unknown-id mutations are ignored, not fatal" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    reg.update("op-99", .running, 1, "x");
    reg.fail("op-99", "y");
    reg.succeed("op-99", "z");
    const ops = try reg.list(std.testing.allocator);
    defer freeList(std.testing.allocator, ops);
    try std.testing.expectEqual(@as(usize, 0), ops.len);
}

test "registry: list is newest first" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    _ = try reg.create(.update_install);
    _ = try reg.create(.wifi_scan);
    const ops = try reg.list(allocator);
    defer freeList(allocator, ops);
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expectEqualStrings("op-2", ops[0].id);
    try std.testing.expectEqualStrings("op-1", ops[1].id);
}

test "registry: bounded at max_operations, oldest finished evicted first" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    // Fill to the cap; finish all but the very first ("op-1" stays running).
    var n: usize = 0;
    while (n < max_operations) : (n += 1) {
        const id = try reg.create(.update_install);
        if (n == 0) {
            reg.update(id, .running, 1, "live");
        } else {
            reg.succeed(id, "done");
        }
    }
    // One over the cap: "op-2" (oldest finished) must go; "op-1" survives.
    _ = try reg.create(.update_install);
    const ops = try reg.list(allocator);
    defer freeList(allocator, ops);
    try std.testing.expectEqual(@as(usize, max_operations), ops.len);
    try std.testing.expect((try reg.get(allocator, "op-2")) == null);
    const survivor = (try reg.get(allocator, "op-1")).?;
    defer freeOperation(allocator, survivor);
    try std.testing.expectEqual(State.running, survivor.state);
}
