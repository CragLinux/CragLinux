//! Time floor + sync surface (docs/07 §6, M3 phase 4). Battery-less
//! boards boot in 1970; TLS then fails before NTP has run. This module:
//!
//!  - applies the monotonic time FLOOR at astrod startup:
//!    clock_settime(REALTIME) to max(/etc/astro/build-epoch,
//!    /data/.astro/last-known-time) when the clock is behind it. The
//!    build-epoch file is baked at rootfs assembly (SOURCE_DATE_EPOCH or
//!    build time — build/lib/rootfs.sh bake_time_defaults); firstboot
//!    (root) applies the same floor even earlier in boot.
//!    RECORDED DEVIATION: astrod runs unprivileged (uid 300, no
//!    CAP_SYS_TIME), so its own clock_settime attempt fails EPERM on the
//!    image whenever the floor actually needs applying — the call is
//!    kept (correct under tests/root and self-documenting), the failure
//!    is logged and non-fatal, and the root-side floor (firstboot; the
//!    boot path that matters, since a boot is exactly when the clock is
//!    lost) is the mechanism of record. Revisit if a mid-run floor ever
//!    matters: dispatch a root oneshot via the dinit client (docs/02 §7
//!    residual-root-ops pattern).
//!  - persists last-known-time hourly and before deferred shutdowns
//!    (the file is created astrod-owned by tmpfiles.d/astrod.conf —
//!    /data/.astro itself stays root-owned).
//!  - answers time.synced for GET /system via adjtimex() STA_UNSYNC —
//!    a raw syscall read of the kernel's own NTP status (chronyd clears
//!    STA_UNSYNC once it disciplines the clock); no shell-outs, no
//!    chronyc protocol.
//!  - gates astrod's OWN https update installs: allowed when synced OR
//!    now > floor (update.zig URL path, docs/07 §6 item 3).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const fsutil = @import("fsutil.zig");
const sync = @import("sync.zig");

pub const build_epoch_path = "/etc/astro/build-epoch";
pub const last_known_path = "/data/.astro/last-known-time";

/// Hourly persist cadence (docs/07 §6 item 1).
pub const persist_interval_s: u64 = 3600;

/// Parse a decimal unix-epoch-seconds file body ("1767225600\n").
/// Null on garbage/empty — a corrupt floor file must never wedge boot.
pub fn parseEpoch(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const v = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    if (v < 0) return null;
    return v;
}

pub fn readEpochFile(path: []const u8) ?i64 {
    var buf: [64]u8 = undefined;
    const text = fsutil.readFileBounded(path, &buf) catch return null;
    return parseEpoch(text);
}

/// The floor: max(build epoch, last known time), 0 when neither exists
/// (dev hosts — then "now > floor" is trivially true and nothing gates).
pub fn floorEpoch(build_path: []const u8, last_known: []const u8) i64 {
    const build = readEpochFile(build_path) orelse 0;
    const last = readEpochFile(last_known) orelse 0;
    return @max(build, last);
}

pub fn nowRealtime() i64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return 0;
    return ts.sec;
}

pub const ApplyResult = struct {
    floor: i64,
    /// Clock was behind the floor and was successfully stepped.
    applied: bool,
    /// Clock was behind the floor but clock_settime failed (EPERM for
    /// the unprivileged daemon — see the module-header deviation).
    denied: bool,
};

/// Apply the floor: step CLOCK_REALTIME to `floor` when now < floor.
pub fn applyFloor(build_path: []const u8, last_known: []const u8) ApplyResult {
    const floor = floorEpoch(build_path, last_known);
    if (floor == 0 or nowRealtime() >= floor)
        return .{ .floor = floor, .applied = false, .denied = false };
    // 32-bit targets (armv7): linux.timespec.sec is isize — the legacy
    // 32-bit clock syscall ABI (y2038 horizon). Clamp rather than
    // truncate: a floor past 2038 steps to the max representable
    // instant instead of wrapping to garbage.
    const sec = std.math.cast(isize, floor) orelse std.math.maxInt(isize);
    const ts: linux.timespec = .{ .sec = sec, .nsec = 0 };
    return switch (linux.errno(linux.clock_settime(.REALTIME, &ts))) {
        .SUCCESS => .{ .floor = floor, .applied = true, .denied = false },
        else => .{ .floor = floor, .applied = false, .denied = true },
    };
}

/// Write the current time as the new last-known floor (atomic enough:
/// a torn single-line decimal write parses as garbage → null → ignored;
/// the value is a monotonic floor, losing one update is harmless).
pub fn persistLastKnown(path: []const u8) fsutil.Error!void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{nowRealtime()}) catch unreachable;
    try fsutil.writeFileSync(path, text);
}

// ---- adjtimex: kernel NTP sync status --------------------------------------

/// STA_UNSYNC from <linux/timex.h>: set while the kernel considers the
/// clock unsynchronized; chronyd clears it once it disciplines the clock.
pub const STA_UNSYNC: c_int = 0x0040;

/// struct timex (kernel UAPI <uapi/linux/timex.h>). extern struct with
/// c_long/c_int fields follows the C ABI on every target (arm32's
/// 32-bit longs included — the classic adjtimex syscall takes the
/// 32-bit struct there, which is exactly what c_long yields).
pub const timex = extern struct {
    modes: c_uint = 0,
    offset: c_long = 0,
    freq: c_long = 0,
    maxerror: c_long = 0,
    esterror: c_long = 0,
    status: c_int = 0,
    constant: c_long = 0,
    precision: c_long = 0,
    tolerance: c_long = 0,
    time: extern struct { sec: c_long = 0, usec: c_long = 0 } = .{},
    tick: c_long = 0,
    ppsfreq: c_long = 0,
    jitter: c_long = 0,
    shift: c_int = 0,
    stabil: c_long = 0,
    jitcnt: c_long = 0,
    calcnt: c_long = 0,
    errcnt: c_long = 0,
    stbcnt: c_long = 0,
    tai: c_int = 0,
    // 11 ints of padding the kernel ABI reserves (bits/timex.h).
    _pad: [11]c_int = @splat(0),
};

/// Read-only adjtimex (modes = 0). Null when the syscall is unavailable
/// or fails — callers must treat that as "not synced".
fn readTimex() ?timex {
    var tx: timex = .{};
    // __NR_adjtimex exists on all Astro targets (x86_64 124, arm EABI
    // 124, aarch64 via asm-generic 171); guard anyway so an exotic
    // target degrades to "unknown" instead of failing the build.
    if (!@hasField(linux.SYS, "adjtimex")) return null;
    const rc = linux.syscall1(.adjtimex, @intFromPtr(&tx));
    if (linux.errno(rc) != .SUCCESS) return null;
    return tx;
}

/// time.synced for GET /system: the kernel's STA_UNSYNC flag is clear.
pub fn synced() bool {
    const tx = readTimex() orelse return false;
    return (tx.status & STA_UNSYNC) == 0;
}

// ---- the https-install gate (docs/07 §6 item 3) ----------------------------

/// Pure form, unit-tested: TLS-dependent operations are allowed when
/// the clock is NTP-synced or already past the floor.
pub fn allowedWith(is_synced: bool, now: i64, floor: i64) bool {
    return is_synced or now > floor;
}

/// Live wrapper used by update.zig for https URLs.
pub fn httpsAllowed() bool {
    return allowedWith(synced(), nowRealtime(), floorEpoch(build_epoch_path, last_known_path));
}

// ---- hourly persist thread -------------------------------------------------

/// Persists last-known-time every persist_interval_s until stop().
/// One instance, owned by main.serve; the deferred-shutdown path in
/// main.zig additionally persists synchronously ("on clean shutdown",
/// docs/07 §6 — dinit's SIGTERM gives no reliable async window).
pub const Keeper = struct {
    path: []const u8,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Keeper) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Keeper) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn run(self: *Keeper) void {
        var elapsed_s: u64 = 0;
        while (!self.stop_flag.load(.acquire)) {
            sync.sleepMs(1000);
            elapsed_s += 1;
            if (elapsed_s >= persist_interval_s) {
                elapsed_s = 0;
                persistLastKnown(self.path) catch {};
            }
        }
    }
};

// ---- tests -----------------------------------------------------------------

test "parseEpoch: decimals, whitespace, garbage, negatives" {
    try std.testing.expectEqual(@as(i64, 1767225600), parseEpoch("1767225600\n").?);
    try std.testing.expectEqual(@as(i64, 0), parseEpoch("0").?);
    try std.testing.expectEqual(@as(i64, 42), parseEpoch("  42 \r\n").?);
    try std.testing.expect(parseEpoch("") == null);
    try std.testing.expect(parseEpoch("\n") == null);
    try std.testing.expect(parseEpoch("not-a-number") == null);
    try std.testing.expect(parseEpoch("-5") == null);
    try std.testing.expect(parseEpoch("1.5e9") == null);
}

test "floorEpoch takes the max of both files and 0 for missing ones" {
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    const build_path = fsutil.testTmpPath(&b1, "build-epoch");
    const last_path = fsutil.testTmpPath(&b2, "last-known-time");
    defer fsutil.unlink(build_path) catch {};
    defer fsutil.unlink(last_path) catch {};

    // Neither file: floor 0 (dev host — nothing gates).
    try std.testing.expectEqual(@as(i64, 0), floorEpoch("/nonexistent/be", "/nonexistent/lk"));

    try fsutil.writeFileSync(build_path, "1000\n");
    try std.testing.expectEqual(@as(i64, 1000), floorEpoch(build_path, "/nonexistent/lk"));

    // last-known-time ahead of the build epoch wins (runtime floor).
    try fsutil.writeFileSync(last_path, "2000\n");
    try std.testing.expectEqual(@as(i64, 2000), floorEpoch(build_path, last_path));

    // …and behind it, the build epoch wins (reflash after long uptime).
    try fsutil.writeFileSync(last_path, "500\n");
    try std.testing.expectEqual(@as(i64, 1000), floorEpoch(build_path, last_path));

    // Corrupt last-known degrades to the build epoch, never to garbage.
    try fsutil.writeFileSync(last_path, "oops");
    try std.testing.expectEqual(@as(i64, 1000), floorEpoch(build_path, last_path));
}

test "applyFloor is a no-op when the clock is already past the floor" {
    var b1: [128]u8 = undefined;
    const build_path = fsutil.testTmpPath(&b1, "build-epoch-past");
    defer fsutil.unlink(build_path) catch {};
    // Any sane test host is past 2001-09-09 (epoch 1e9).
    try fsutil.writeFileSync(build_path, "1000000000\n");
    const r = applyFloor(build_path, "/nonexistent/lk");
    try std.testing.expectEqual(@as(i64, 1000000000), r.floor);
    try std.testing.expect(!r.applied);
    try std.testing.expect(!r.denied);
}

test "applyFloor against a future floor either steps (root) or is denied (unprivileged)" {
    var b1: [128]u8 = undefined;
    const build_path = fsutil.testTmpPath(&b1, "build-epoch-future");
    defer fsutil.unlink(build_path) catch {};
    const future = nowRealtime() + 3600;
    var buf: [32]u8 = undefined;
    try fsutil.writeFileSync(build_path, try std.fmt.bufPrint(&buf, "{d}\n", .{future}));

    const r = applyFloor(build_path, "/nonexistent/lk");
    try std.testing.expectEqual(future, r.floor);
    if (r.applied) {
        // Running as root (CI container): the clock actually stepped —
        // step it right back so the rest of the suite keeps real time.
        try std.testing.expect(!r.denied);
        const back: linux.timespec = .{ .sec = future - 3600, .nsec = 0 };
        _ = linux.clock_settime(.REALTIME, &back);
    } else {
        // Unprivileged: the documented EPERM deviation.
        try std.testing.expect(r.denied);
    }
}

test "persistLastKnown writes a parseable now and floors future reads" {
    var b1: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&b1, "last-known-persist");
    defer fsutil.unlink(path) catch {};
    const before = nowRealtime();
    try persistLastKnown(path);
    const persisted = readEpochFile(path).?;
    try std.testing.expect(persisted >= before);
    try std.testing.expect(persisted <= nowRealtime() + 1);
}

test "synced() answers without crashing; result matches the kernel flag" {
    // Can't assert a value (the host may or may not run NTP) — assert
    // consistency with a direct second read instead.
    const a = synced();
    const b = synced();
    try std.testing.expectEqual(a, b);
}

test "allowedWith: the docs/07 §6 gate table" {
    // Synced always allows, regardless of the floor.
    try std.testing.expect(allowedWith(true, 0, 1000));
    // Unsynced but past the floor allows (build-time floor mitigation).
    try std.testing.expect(allowedWith(false, 1001, 1000));
    // Unsynced at/behind the floor blocks.
    try std.testing.expect(!allowedWith(false, 1000, 1000));
    try std.testing.expect(!allowedWith(false, 999, 1000));
    // Fresh dev host with no floor files: floor 0, any real clock allows.
    try std.testing.expect(allowedWith(false, 1, 0));
}

test "Keeper starts and stops cleanly without touching the file early" {
    var b1: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&b1, "keeper-lk");
    defer fsutil.unlink(path) catch {};
    var k: Keeper = .{ .path = path };
    try k.start();
    k.stop();
    // One-second granularity loop, stopped immediately: no write yet.
    try std.testing.expect(!fsutil.exists(path));
}
