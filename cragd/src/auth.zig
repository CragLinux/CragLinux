//! Authentication for the AD-014 surfaces:
//!  - unix socket: filesystem-gated by group astro-api; peer is trusted.
//!  - 127.0.0.1 TCP (localhost) and opt-in LAN: Bearer token from
//!    /data/config/api-token.
//!  - AP provisioning listener: no bearer token — the router serves ONLY
//!    the unauthenticated subset there (docs/06 §6; router.apAllowed)
//!    and answers 403 for everything else. Transport-level auth is the
//!    AP's WPA2 PSK (printed on the device label).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const fsutil = @import("fsutil.zig");
const sync = @import("sync.zig");

pub const default_token_path = "/data/config/api-token";

/// Listener surfaces (AD-014 table, docs/06 §6). Every listener fd is
/// tagged at bind time; the tag rides the Context into the router so
/// auth AND route policy can differ per surface:
///   unix      /run/astro/astrod.sock — group-gated, no token
///   localhost 127.0.0.1:8080         — bearer token
///   lan       0.0.0.0 (opt-in, AD-025 default off; phase-4 spine only
///             carries the tag — the LAN listener itself is future fill)
///   ap        192.168.223.1:8080 while AP mode is up — unauthenticated
///             SUBSET only (router.apAllowed), everything else 403
pub const Surface = enum { unix, localhost, lan, ap };

/// Per-surface admission (AD-014). AP returns true here because the AP
/// surface's restriction is a ROUTE whitelist, not a credential — the
/// router enforces it (403), keeping "who may connect" and "what this
/// surface serves" separately testable.
pub fn authorize(surface: Surface, token_file_path: []const u8, header_value: ?[]const u8) bool {
    return switch (surface) {
        .unix => allowUnixPeer(),
        .localhost, .lan => checkBearer(token_file_path, header_value),
        .ap => true,
    };
}

// Token file is firstboot-generated ASCII; anything longer than this is
// not ours and safely rejected.
const max_token_len = 256;
const max_path_len = 256;

// In-memory token cache, reloaded when the file identity changes. The key
// is (path, inode, size, mtime) rather than mtime alone because file
// timestamps use the kernel's coarse clock — two rewrites within one tick
// share an mtime. The daemon serves connections concurrently, so all
// cache access (including the compare against the cached slice) happens
// under cache_mu — see checkBearer.
const TokenCache = struct {
    valid: bool = false,
    path_buf: [max_path_len]u8 = undefined,
    path_len: usize = 0,
    ino: u64 = 0,
    size: u64 = 0,
    mtime_sec: i64 = 0,
    mtime_nsec: u32 = 0,
    token_buf: [max_token_len]u8 = undefined,
    token_len: usize = 0,
};
var cache: TokenCache = .{};
/// Guards `cache` (connection threads race on it). Held across the whole
/// check: the compare reads the cached slice, so releasing earlier would
/// let a concurrent reload swap the bytes mid-comparison.
var cache_mu: sync.Mutex = .{};

/// Compare the request's Authorization header against the on-disk token.
/// Fail-closed: missing header, missing/unreadable/oversized token file, or
/// empty token all deny. Comparison is constant-time in the token contents;
/// only the length mismatch is observable, which is standard practice.
/// Thread-safe (cache_mu).
pub fn checkBearer(token_file_path: []const u8, header_value: ?[]const u8) bool {
    const header = header_value orelse return false;
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, header, prefix)) return false;
    const presented = header[prefix.len..];

    cache_mu.lock();
    defer cache_mu.unlock();
    const expected = cachedToken(token_file_path) orelse return false;
    return constantTimeEql(expected, presented);
}

/// Unix-socket peers passed the astro-api group gate at connect() time.
/// TODO(fill): SO_PEERCRED logging of uid/pid for the audit trail.
pub fn allowUnixPeer() bool {
    return true;
}

/// Return the trimmed token, from cache when the file is unchanged. Any
/// failure invalidates the cache and denies (null): a deleted token file
/// must not keep authenticating from memory. Caller holds cache_mu.
fn cachedToken(path: []const u8) ?[]const u8 {
    if (path.len > max_path_len) {
        // Longer paths would silently bypass caching; the deployed path is
        // short and fixed, so reject outright instead of special-casing.
        cache.valid = false;
        return null;
    }

    // stat *before* read: if the file changes in between, the cached mtime
    // is older than the content actually read, so the next request notices
    // the mismatch and reloads — the race self-corrects toward freshness.
    const path_z = posix.toPosixPath(path) catch {
        cache.valid = false;
        return null;
    };
    var stx: linux.Statx = undefined;
    const want: linux.STATX = .{ .INO = true, .SIZE = true, .MTIME = true };
    if (linux.errno(linux.statx(linux.AT.FDCWD, &path_z, 0, want, &stx)) != .SUCCESS) {
        cache.valid = false;
        return null;
    }

    if (cache.valid and
        std.mem.eql(u8, cache.path_buf[0..cache.path_len], path) and
        cache.ino == stx.ino and cache.size == stx.size and
        cache.mtime_sec == stx.mtime.sec and cache.mtime_nsec == stx.mtime.nsec)
    {
        return cache.token_buf[0..cache.token_len];
    }

    cache.valid = false;
    var buf: [max_token_len]u8 = undefined;
    const raw = fsutil.readFileBounded(path, &buf) catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    @memcpy(cache.path_buf[0..path.len], path);
    cache.path_len = path.len;
    cache.ino = stx.ino;
    cache.size = stx.size;
    cache.mtime_sec = stx.mtime.sec;
    cache.mtime_nsec = stx.mtime.nsec;
    @memcpy(cache.token_buf[0..trimmed.len], trimmed);
    cache.token_len = trimmed.len;
    cache.valid = true;
    return cache.token_buf[0..cache.token_len];
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

test "checkBearer accepts the exact token and rejects everything else" {
    var path_buf: [128]u8 = undefined;
    const token_path = fsutil.testTmpPath(&path_buf, "api-token");
    defer fsutil.unlink(token_path) catch {};
    try fsutil.writeFileSync(token_path, "s3cret-token\n");

    try std.testing.expect(checkBearer(token_path, "Bearer s3cret-token"));
    try std.testing.expect(!checkBearer(token_path, "Bearer wrong-token!"));
    try std.testing.expect(!checkBearer(token_path, "Bearer s3cret-token-longer"));
    try std.testing.expect(!checkBearer(token_path, "Basic s3cret-token"));
    try std.testing.expect(!checkBearer(token_path, null));
}

test "checkBearer fails closed when the token file is absent" {
    try std.testing.expect(!checkBearer("/nonexistent/api-token", "Bearer anything"));
}

test "token is trimmed of surrounding whitespace, not of inner bytes" {
    var path_buf: [128]u8 = undefined;
    const token_path = fsutil.testTmpPath(&path_buf, "trim-token");
    defer fsutil.unlink(token_path) catch {};
    try fsutil.writeFileSync(token_path, " \ttok-en\r\n");

    try std.testing.expect(checkBearer(token_path, "Bearer tok-en"));
    try std.testing.expect(!checkBearer(token_path, "Bearer  tok-en"));
    try std.testing.expect(!checkBearer(token_path, "Bearer tok-en "));
}

test "cache reloads when the token file changes and drops when it vanishes" {
    var path_buf: [128]u8 = undefined;
    const token_path = fsutil.testTmpPath(&path_buf, "rotate-token");
    defer fsutil.unlink(token_path) catch {};

    // Different lengths keep the cache key distinct even when the two
    // writes land within one coarse-mtime tick.
    try fsutil.writeFileSync(token_path, "first-token\n");
    try std.testing.expect(checkBearer(token_path, "Bearer first-token"));

    try fsutil.writeFileSync(token_path, "second-token-longer\n");
    try std.testing.expect(!checkBearer(token_path, "Bearer first-token"));
    try std.testing.expect(checkBearer(token_path, "Bearer second-token-longer"));

    // Deleting the file must deny immediately, not serve from memory.
    try fsutil.unlink(token_path);
    try std.testing.expect(!checkBearer(token_path, "Bearer second-token-longer"));
}

test "constantTimeEql basics" {
    try std.testing.expect(constantTimeEql("abc", "abc"));
    try std.testing.expect(!constantTimeEql("abc", "abd"));
    try std.testing.expect(!constantTimeEql("abc", "ab"));
}

test "authorize: per-surface policy (AD-014)" {
    var path_buf: [128]u8 = undefined;
    const token_path = fsutil.testTmpPath(&path_buf, "surface-token");
    defer fsutil.unlink(token_path) catch {};
    try fsutil.writeFileSync(token_path, "tok-1\n");

    // unix: group-gated at connect, header irrelevant.
    try std.testing.expect(authorize(.unix, token_path, null));
    // localhost/lan: bearer token required.
    try std.testing.expect(authorize(.localhost, token_path, "Bearer tok-1"));
    try std.testing.expect(!authorize(.localhost, token_path, null));
    try std.testing.expect(!authorize(.localhost, token_path, "Bearer nope"));
    try std.testing.expect(authorize(.lan, token_path, "Bearer tok-1"));
    try std.testing.expect(!authorize(.lan, token_path, null));
    // ap: admission always passes; the ROUTER enforces the subset (403).
    try std.testing.expect(authorize(.ap, token_path, null));
    try std.testing.expect(authorize(.ap, "/nonexistent/token", null));
}
