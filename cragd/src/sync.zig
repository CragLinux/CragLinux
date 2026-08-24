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
