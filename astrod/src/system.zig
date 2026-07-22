//! System info collection (GET /api/v1/system, docs/06 §5.1).
//!
//! Sources: /etc/os-release (identity), /proc/cmdline (RAUC booted slot),
//! /proc/uptime, /etc/machine-id. All reads are fail-soft: a missing or
//! malformed source degrades one field to its fallback, never the endpoint.

const std = @import("std");
const fsutil = @import("fsutil.zig");
const timekeep = @import("timekeep.zig");

pub const SystemInfo = struct {
    board: []const u8,
    variant: []const u8,
    release: []const u8,
    /// null = no rauc.slot= on the kernel cmdline: a direct kernel boot
    /// (dev QEMU) rather than a RAUC-managed slot. Serialized as JSON null.
    booted_slot: ?[]const u8,
    machine_id: []const u8,
    uptime_s: u64,
    provisioning: []const u8,
    health: []const u8,
    /// Kernel NTP discipline state (docs/07 §6 item 3): adjtimex
    /// STA_UNSYNC clear — chronyd sets it once it steps/slews the clock.
    /// Product apps gate their own TLS-dependent work on this.
    time_synced: bool,
    /// Last provisioning-AP failure ("ap-start-failed"/"ap-stop-failed",
    /// static strings from portal.ApController via last_error_source);
    /// null when the last AP cycle was clean. Kept in the REDACTED view
    /// too — the portal page displays it and re-offers the form (the
    /// survivable wrong-password loop, docs/07 §4 item 5).
    last_error: ?[]const u8,
};

/// GET /system on the AP provisioning surface (AD-014, docs/06 §6):
/// the unauthenticated subset serves a REDACTED system summary —
/// machine_id is omitted (it seeds the AP PSK derivation and is the
/// factory-reset confirm token; provisioning/version stay, the portal
/// needs them). Field subset of SystemInfo, enforced by a test below.
pub const RedactedSystemInfo = struct {
    board: []const u8,
    variant: []const u8,
    release: []const u8,
    booted_slot: ?[]const u8,
    uptime_s: u64,
    provisioning: []const u8,
    health: []const u8,
    time_synced: bool,
    last_error: ?[]const u8,
};

pub fn redact(info: SystemInfo) RedactedSystemInfo {
    return .{
        .board = info.board,
        .variant = info.variant,
        .release = info.release,
        .booted_slot = info.booted_slot,
        .uptime_s = info.uptime_s,
        .provisioning = info.provisioning,
        .health = info.health,
        .time_synced = info.time_synced,
        .last_error = info.last_error,
    };
}

/// Source of the last_error field: main wires portal.lastErrorSource
/// here at startup (a fn pointer rather than an import keeps system.zig
/// dependency-flat and the unit builds deterministic — null source
/// serves last_error: null). Must return null or a STATIC string.
pub var last_error_source: ?*const fn () ?[]const u8 = null;

/// TODO(fill): reconciler summary (docs/06 §2) replaces this constant.
pub const health_ok = "ok";

const os_release_path = "/etc/os-release";
const cmdline_path = "/proc/cmdline";
const uptime_path = "/proc/uptime";
const machine_id_path = "/etc/machine-id";
const fallback = "unknown";

/// Store-less variant: provisioning reads as "factory", matching the store
/// default for a device with no config document. The wired handler should
/// call collectWith(allocator, store.getProvisioning()) instead.
pub fn collect(allocator: std.mem.Allocator) error{OutOfMemory}!SystemInfo {
    return collectWith(allocator, "factory");
}

/// All file-derived strings are copied into `allocator` (per-request arena
/// in the daemon), so concurrent collectors never share buffers — the old
/// module-static interning was only safe single-connection-at-a-time.
pub fn collectWith(allocator: std.mem.Allocator, provisioning: []const u8) error{OutOfMemory}!SystemInfo {
    var file_buf: [4096]u8 = undefined;

    var board: []const u8 = fallback;
    var variant: []const u8 = fallback;
    var release: []const u8 = fallback;
    if (fsutil.readFileBounded(os_release_path, &file_buf)) |text| {
        const id = parseOsRelease(text);
        if (id.board) |v| board = try allocator.dupe(u8, v);
        if (id.variant) |v| variant = try allocator.dupe(u8, v);
        if (id.release) |v| release = try allocator.dupe(u8, v);
    } else |_| {}

    var booted_slot: ?[]const u8 = null;
    if (fsutil.readFileBounded(cmdline_path, &file_buf)) |text| {
        if (parseBootedSlot(text)) |v| booted_slot = try allocator.dupe(u8, v);
    } else |_| {}

    var machine_id: []const u8 = fallback;
    if (fsutil.readFileBounded(machine_id_path, &file_buf)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) machine_id = try allocator.dupe(u8, trimmed);
    } else |_| {}

    return .{
        .board = board,
        .variant = variant,
        .release = release,
        .booted_slot = booted_slot,
        .machine_id = machine_id,
        .uptime_s = uptimeSeconds(),
        .provisioning = provisioning,
        .health = health_ok,
        .time_synced = timekeep.synced(),
        .last_error = if (last_error_source) |f| f() else null,
    };
}

pub const OsReleaseInfo = struct {
    board: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    release: ?[]const u8 = null,
};

/// os-release KEY=VALUE lines, values optionally double-quoted. Explicit
/// ASTRO_* keys win over the generic fields so images can stamp board and
/// variant identity without repurposing standard keys. The rootfs stage
/// stamps them into /usr/lib/os-release (the canonical document —
/// /etc/os-release is a tmpfiles-recreated symlink to it; see
/// stamp_os_release in build/lib/rootfs.sh). Returned slices point into
/// `text`.
pub fn parseOsRelease(text: []const u8) OsReleaseInfo {
    var info: OsReleaseInfo = .{};
    var astro_variant: ?[]const u8 = null;
    var astro_release: ?[]const u8 = null;
    var generic_variant: ?[]const u8 = null;
    var version_id: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = unquote(line[eq + 1 ..]);
        if (value.len == 0) continue;

        if (std.mem.eql(u8, key, "ASTRO_BOARD")) {
            info.board = value;
        } else if (std.mem.eql(u8, key, "ASTRO_VARIANT")) {
            astro_variant = value;
        } else if (std.mem.eql(u8, key, "ASTRO_RELEASE")) {
            astro_release = value;
        } else if (std.mem.eql(u8, key, "VARIANT")) {
            generic_variant = value;
        } else if (std.mem.eql(u8, key, "VERSION_ID")) {
            version_id = value;
        }
    }
    info.variant = astro_variant orelse generic_variant;
    info.release = astro_release orelse version_id;
    return info;
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;
}

/// rauc.slot=<name> from the kernel cmdline (RAUC's uboot/grub handlers
/// both inject it). Whitespace-tokenized exact-prefix match so keys like
/// "notrauc.slot=" cannot false-positive. Returned slice points into
/// `cmdline`.
pub fn parseBootedSlot(cmdline: []const u8) ?[]const u8 {
    const key = "rauc.slot=";
    var tokens = std.mem.tokenizeAny(u8, cmdline, " \t\n");
    while (tokens.next()) |tok| {
        if (std.mem.startsWith(u8, tok, key) and tok.len > key.len) {
            return tok[key.len..];
        }
    }
    return null;
}

/// First field of /proc/uptime ("123.45 67.89\n") truncated to whole
/// seconds; null on malformed input.
pub fn parseUptimeSeconds(text: []const u8) ?u64 {
    const end = std.mem.indexOfAny(u8, text, ". \t\n") orelse text.len;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, text[0..end], 10) catch null;
}

fn uptimeSeconds() u64 {
    var buf: [64]u8 = undefined;
    if (fsutil.readFileBounded(uptime_path, &buf)) |text| {
        if (parseUptimeSeconds(text)) |s| return s;
    } else |_| {}
    // Fallback: CLOCK_BOOTTIME, the clock /proc/uptime derives from.
    // Raw syscall: Zig 0.16 removed posix.clock_gettime; Linux-only is fine.
    const linux = std.os.linux;
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.BOOTTIME, &ts)) != .SUCCESS) return 0;
    return @intCast(@max(0, ts.sec));
}

// ---- tests -----------------------------------------------------------------

test "parseOsRelease handles the shipped common-overlay document" {
    // Verbatim from boards/common/overlay/usr/lib/os-release (pre-stamp).
    const fixture =
        \\NAME="Astro Linux"
        \\ID=astro
        \\ID_LIKE=chimera
        \\VERSION_ID=0.1.0
        \\PRETTY_NAME="Astro Linux 0.1.0"
        \\HOME_URL="https://github.com/tierone/clang-cross"
        \\
    ;
    const id = parseOsRelease(fixture);
    try std.testing.expect(id.board == null);
    try std.testing.expect(id.variant == null);
    try std.testing.expectEqualStrings("0.1.0", id.release.?);
}

test "parseOsRelease prefers ASTRO_* keys and unquotes values" {
    const fixture =
        \\VERSION_ID=0.1.0
        \\VARIANT="Development"
        \\ASTRO_BOARD=qemu-aarch64
        \\ASTRO_VARIANT="dev"
        \\ASTRO_RELEASE=0.2.0-rc1
        \\# comment line
        \\MALFORMED_NO_EQUALS
        \\EMPTY=
        \\
    ;
    const id = parseOsRelease(fixture);
    try std.testing.expectEqualStrings("qemu-aarch64", id.board.?);
    try std.testing.expectEqualStrings("dev", id.variant.?);
    try std.testing.expectEqualStrings("0.2.0-rc1", id.release.?);
}

test "parseOsRelease falls back to VARIANT when ASTRO_VARIANT is absent" {
    const id = parseOsRelease("VARIANT=prod\nVERSION_ID=1.0.0\n");
    try std.testing.expectEqualStrings("prod", id.variant.?);
    try std.testing.expectEqualStrings("1.0.0", id.release.?);
}

test "parseBootedSlot extracts rauc.slot from the cmdline" {
    try std.testing.expectEqualStrings(
        "A",
        parseBootedSlot("console=ttyAMA0,115200 rauc.slot=A root=PARTLABEL=system-a rw\n").?,
    );
    // Slot token at the very end, newline-terminated.
    try std.testing.expectEqualStrings("B", parseBootedSlot("quiet rauc.slot=B\n").?);
    // Direct boot: no slot key → null.
    try std.testing.expect(parseBootedSlot("console=ttyAMA0 root=/dev/vda2 rw\n") == null);
    // Prefix must match a whole token key; empty value is not a slot.
    try std.testing.expect(parseBootedSlot("notrauc.slot=X\n") == null);
    try std.testing.expect(parseBootedSlot("rauc.slot= quiet\n") == null);
}

test "parseUptimeSeconds truncates to whole seconds" {
    try std.testing.expectEqual(@as(u64, 123), parseUptimeSeconds("123.45 67.89\n").?);
    try std.testing.expectEqual(@as(u64, 0), parseUptimeSeconds("0.00 0.00\n").?);
    try std.testing.expect(parseUptimeSeconds("garbage\n") == null);
    try std.testing.expect(parseUptimeSeconds("") == null);
}

test "collect returns populated fields with real uptime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = try collect(arena.allocator());
    try std.testing.expect(info.board.len > 0);
    try std.testing.expect(info.release.len > 0);
    try std.testing.expectEqualStrings(health_ok, info.health);
    try std.testing.expectEqualStrings("factory", info.provisioning);
    // Uptime is real; on any running system it is > 0.
    try std.testing.expect(info.uptime_s > 0);
}

test "collectWith threads the store's provisioning state through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = try collectWith(arena.allocator(), "provisioned");
    try std.testing.expectEqualStrings("provisioned", info.provisioning);
}

test "RedactedSystemInfo is SystemInfo minus exactly machine_id" {
    // Structural guarantee for the AP surface: every redacted field
    // exists on SystemInfo with the same type, and the only field
    // removed is machine_id — a new SystemInfo field that is forgotten
    // in RedactedSystemInfo (or vice versa) fails here, forcing a
    // deliberate redaction decision.
    const full = std.meta.fields(SystemInfo);
    const red = std.meta.fields(RedactedSystemInfo);
    try std.testing.expectEqual(full.len, red.len + 1);
    inline for (red) |rf| {
        var found = false;
        inline for (full) |ff| {
            if (comptime std.mem.eql(u8, ff.name, rf.name)) {
                try std.testing.expect(ff.type == rf.type);
                found = true;
            }
        }
        try std.testing.expect(found);
        try std.testing.expect(comptime !std.mem.eql(u8, rf.name, "machine_id"));
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = try collectWith(arena.allocator(), "provisioning");
    const r = redact(info);
    try std.testing.expectEqualStrings("provisioning", r.provisioning);
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), r, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "machine_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "time_synced") != null);
}
