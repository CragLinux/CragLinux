//! Release-version comparison for the AD-021 monotonic-update gate
//! (docs/05 §6): astrod refuses to install a bundle whose version is lower
//! than the running release unless the request carries {"force": true}.
//!
//! Scheme (deliberately simple, matches ASTRO_RELEASE / bundle versions
//! like "0.1.0", "0.2.0-rc1", "0.0.0-dev"):
//!  - split off an optional suffix at the FIRST '-'; the base is compared
//!    as dotted segments, numerically when both segments are numeric,
//!    lexicographically otherwise; missing segments count as "0".
//!  - equal bases: a version WITHOUT a suffix outranks one with a suffix
//!    ("1.0.0" > "1.0.0-rc1", the semver pre-release rule); two suffixes
//!    compare lexicographically (bytewise — "rc10" < "rc9" is accepted
//!    and documented; use rc09-style padding if that matters).

const std = @import("std");

pub const Order = std.math.Order;

/// Total order over version strings. Never errors: any string compares
/// (garbage compares lexicographically), so a malformed bundle version
/// cannot crash the gate — it just orders conservatively.
pub fn compare(a: []const u8, b: []const u8) Order {
    const va = split(a);
    const vb = split(b);

    var ita = std.mem.splitScalar(u8, va.base, '.');
    var itb = std.mem.splitScalar(u8, vb.base, '.');
    while (true) {
        const sa = ita.next();
        const sb = itb.next();
        if (sa == null and sb == null) break;
        const seg_a = sa orelse "0";
        const seg_b = sb orelse "0";
        const ord = compareSegment(seg_a, seg_b);
        if (ord != .eq) return ord;
    }

    // Bases equal: no-suffix > any suffix; two suffixes are lexicographic.
    if (va.suffix == null and vb.suffix == null) return .eq;
    if (va.suffix == null) return .gt;
    if (vb.suffix == null) return .lt;
    return std.mem.order(u8, va.suffix.?, vb.suffix.?);
}

/// The AD-021 gate predicate: is installing `candidate` over `running` a
/// downgrade (to be refused without force)?
pub fn isDowngrade(candidate: []const u8, running: []const u8) bool {
    return compare(candidate, running) == .lt;
}

const Split = struct { base: []const u8, suffix: ?[]const u8 };

fn split(v: []const u8) Split {
    if (std.mem.indexOfScalar(u8, v, '-')) |i|
        return .{ .base = v[0..i], .suffix = v[i + 1 ..] };
    return .{ .base = v, .suffix = null };
}

fn compareSegment(a: []const u8, b: []const u8) Order {
    const na = std.fmt.parseInt(u64, a, 10) catch null;
    const nb = std.fmt.parseInt(u64, b, 10) catch null;
    if (na != null and nb != null) return std.math.order(na.?, nb.?);
    // Mixed or non-numeric segments: lexicographic keeps the order total.
    return std.mem.order(u8, a, b);
}

// ---- tests ------------------------------------------------------------------

test "numeric dotted comparison" {
    try std.testing.expectEqual(Order.eq, compare("1.2.3", "1.2.3"));
    try std.testing.expectEqual(Order.lt, compare("1.2.3", "1.2.4"));
    try std.testing.expectEqual(Order.gt, compare("1.10.0", "1.9.9"));
    try std.testing.expectEqual(Order.gt, compare("2.0.0", "1.99.99"));
    try std.testing.expectEqual(Order.lt, compare("0.9", "0.10"));
}

test "missing segments count as zero" {
    try std.testing.expectEqual(Order.eq, compare("1.2", "1.2.0"));
    try std.testing.expectEqual(Order.lt, compare("1.2", "1.2.1"));
    try std.testing.expectEqual(Order.gt, compare("1.2.0.1", "1.2"));
}

test "suffix rules: release outranks pre-release, suffixes lexicographic" {
    try std.testing.expectEqual(Order.gt, compare("1.0.0", "1.0.0-rc1"));
    try std.testing.expectEqual(Order.lt, compare("1.0.0-rc1", "1.0.0"));
    try std.testing.expectEqual(Order.lt, compare("1.0.0-rc1", "1.0.0-rc2"));
    try std.testing.expectEqual(Order.lt, compare("0.0.0-dev", "0.0.0"));
    try std.testing.expectEqual(Order.eq, compare("0.2.0-rc1", "0.2.0-rc1"));
    // Suffix only breaks ties — a higher base beats any suffix state.
    try std.testing.expectEqual(Order.gt, compare("1.0.1-dev", "1.0.0"));
}

test "non-numeric segments fall back to lexicographic, order stays total" {
    try std.testing.expectEqual(Order.lt, compare("1.a.0", "1.b.0"));
    try std.testing.expectEqual(Order.eq, compare("abc", "abc"));
    try std.testing.expectEqual(Order.gt, compare("1.2.3", "")); // "" = base "0"-ish, still ordered
}

test "isDowngrade drives the AD-021 gate" {
    try std.testing.expect(isDowngrade("0.1.0", "0.2.0"));
    try std.testing.expect(!isDowngrade("0.2.0", "0.2.0")); // same version: allowed
    try std.testing.expect(!isDowngrade("0.3.0", "0.2.0"));
    try std.testing.expect(isDowngrade("0.2.0-rc1", "0.2.0"));
    try std.testing.expect(!isDowngrade("0.2.0", "0.2.0-rc1"));
    try std.testing.expect(!isDowngrade("0.0.0-dev", "0.0.0-dev"));
}
