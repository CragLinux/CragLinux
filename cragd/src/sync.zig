//! Thread-synchronization primitives over musl pthreads.
//!
//! Zig 0.16 moved std's Mutex/RwLock behind the std.Io interface
//! (Io.Mutex.lock(io), futex via the Io vtable); this codebase deliberately
//! keeps std.Io out of daemon code (see fsutil.zig rationale), and cragd
//! links musl libc anyway for basu — so the locks come straight from
//! pthreads. Zero-initialized pthread types ARE the static initializers on
//! musl (PTHREAD_*_INITIALIZER is all-zeroes), hence `.{}` defaults work.
//!
//! API mirrors the pre-0.16 std.Thread.{Mutex,RwLock} so a future std
//! solution can swap back in mechanically.

const std = @import("std");

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }
};

pub const RwLock = struct {
    inner: std.c.pthread_rwlock_t = .{},

    pub fn lock(self: *RwLock) void {
        const rc = std.c.pthread_rwlock_wrlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(self: *RwLock) void {
        const rc = std.c.pthread_rwlock_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn lockShared(self: *RwLock) void {
        const rc = std.c.pthread_rwlock_rdlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlockShared(self: *RwLock) void {
        const rc = std.c.pthread_rwlock_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }
};

/// Sleep helper for retry/backoff loops (std.Thread.sleep is gone; Io.sleep
/// needs an Io instance).
pub fn sleepMs(ms: u64) void {
    if (ms == 0) return;
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    var rem: std.c.timespec = undefined;
    // Retry on EINTR so callers get the full delay.
    while (true) {
        const rc = std.c.nanosleep(&ts, &rem);
        if (rc == 0) return;
        if (std.posix.errno(rc) != .INTR) return;
        ts = rem;
    }
}

// ---- tests ------------------------------------------------------------------

test "mutex: exclusion across real threads" {
    var mu: Mutex = .{};
    var counter: u64 = 0;
    const Worker = struct {
        fn run(m: *Mutex, n: *u64) void {
            for (0..10_000) |_| {
                m.lock();
                n.* += 1;
                m.unlock();
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &mu, &counter });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 40_000), counter);
}

test "rwlock: shared and exclusive paths do not deadlock" {
    var rw: RwLock = .{};
    rw.lockShared();
    rw.lockShared(); // recursive shared acquisition is legal for pthreads
    rw.unlockShared();
    rw.unlockShared();
    rw.lock();
    rw.unlock();
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &ts);
    std.debug.assert(rc == 0);
    return @intCast(@as(i128, ts.sec) * 1000 + @divTrunc(@as(i128, ts.nsec), 1_000_000));
}

test "sleepMs: zero is a no-op, a positive delay never returns early" {
    sleepMs(0);
    const start = monotonicMs();
    sleepMs(25);
    try std.testing.expect(monotonicMs() - start >= 25);
}

test "rwlock: exclusive writers exclude shared readers across threads" {
    // Writer bumps n and its doubled shadow under the exclusive lock;
    // readers verify the invariant under the shared lock. Without real
    // exclusion a reader would observe the half-updated pair.
    var rw: RwLock = .{};
    var n: u64 = 0;
    var twice: u64 = 0;

    const Worker = struct {
        fn writer(r: *RwLock, a: *u64, b: *u64) void {
            for (0..20_000) |_| {
                r.lock();
                a.* += 1;
                b.* = a.* * 2;
                r.unlock();
            }
        }
        fn reader(r: *RwLock, a: *u64, b: *u64, bad: *u64) void {
            for (0..20_000) |_| {
                r.lockShared();
                const x = a.*;
                const y = b.*;
                r.unlockShared();
                if (y != x * 2) bad.* += 1;
            }
        }
    };

    var bad1: u64 = 0;
    var bad2: u64 = 0;
    const t1 = try std.Thread.spawn(.{}, Worker.writer, .{ &rw, &n, &twice });
    const t2 = try std.Thread.spawn(.{}, Worker.reader, .{ &rw, &n, &twice, &bad1 });
    const t3 = try std.Thread.spawn(.{}, Worker.reader, .{ &rw, &n, &twice, &bad2 });
    t1.join();
    t2.join();
    t3.join();
    try std.testing.expectEqual(@as(u64, 20_000), n);
    try std.testing.expectEqual(@as(u64, 0), bad1);
    try std.testing.expectEqual(@as(u64, 0), bad2);
}
