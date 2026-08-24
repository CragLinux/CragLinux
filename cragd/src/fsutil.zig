//! Path-based file helpers over raw Linux syscalls.
//!
//! Zig 0.16 moved std filesystem access behind the std.Io interface; the
//! store/auth interfaces in this skeleton are deliberately path-based and
//! synchronous (cragd is Linux-only, files are tiny), so these ~few
//! wrappers keep std.Io out of the module signatures. If a fill agent
//! later threads std.Io through the daemon, this module is the only
//! place to swap.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Error = error{ FileNotFound, NameTooLong, FileTooBig, Unexpected, OutOfMemory, InputOutput };

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOENT => error.FileNotFound,
        else => |e| posix.unexpectedErrno(e),
    };
}

fn openat(path: []const u8, flags: linux.O, mode: linux.mode_t) Error!posix.fd_t {
    const path_z = posix.toPosixPath(path) catch return error.NameTooLong;
    const fd = try check(linux.openat(linux.AT.FDCWD, &path_z, flags, mode));
    return @intCast(fd);
}

/// Read an entire file; caller owns the slice. Errors if larger than `limit`.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) Error![]u8 {
    const fd = try openat(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer _ = linux.close(fd);

    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch return error.InputOutput;
        if (n == 0) break;
        if (data.items.len + n > limit) return error.FileTooBig;
        try data.appendSlice(allocator, buf[0..n]);
    }
    return data.toOwnedSlice(allocator);
}

/// Read into a caller-provided buffer (for no-allocation paths like the
/// auth token check). Errors with FileTooBig if the file exceeds `buf`.
pub fn readFileBounded(path: []const u8, buf: []u8) Error![]u8 {
    const fd = try openat(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer _ = linux.close(fd);

    var len: usize = 0;
    while (len < buf.len) {
        const n = posix.read(fd, buf[len..]) catch return error.InputOutput;
        if (n == 0) return buf[0..len];
        len += n;
    }
    // Buffer full: distinguish exact fit from truncation with one more read.
    var probe: [1]u8 = undefined;
    const extra = posix.read(fd, &probe) catch return error.InputOutput;
    if (extra != 0) return error.FileTooBig;
    return buf[0..len];
}

/// Create/truncate + write + fsync. Durability of the *name* still needs a
/// parent-dir fsync after rename — the store's TODO, not handled here.
pub fn writeFileSync(path: []const u8, bytes: []const u8) Error!void {
    const fd = try openat(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    defer _ = linux.close(fd);
    try writeAllFd(fd, bytes);
    _ = try check(linux.fsync(fd));
}

/// Create/truncate + stream exactly `total_len` bytes + fsync: an
/// already-read `prefix` first, the rest pulled from `reader` (anything
/// with `read([]u8) !usize`; 0 before total_len is a short body and an
/// error). Bundle uploads are far larger than the daemon's RSS budget, so
/// the HTTP layer hands the socket-backed reader straight through here
/// instead of buffering the body (docs/06 §7).
pub fn writeStreamSync(path: []const u8, prefix: []const u8, reader: anytype, total_len: u64) Error!void {
    const fd = try openat(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    defer _ = linux.close(fd);
    try writeAllFd(fd, prefix);
    var done: u64 = prefix.len;
    var buf: [64 * 1024]u8 = undefined;
    while (done < total_len) {
        const want: usize = @intCast(@min(@as(u64, buf.len), total_len - done));
        const n = reader.read(buf[0..want]) catch return error.InputOutput;
        if (n == 0) return error.InputOutput; // peer closed mid-body
        try writeAllFd(fd, buf[0..n]);
        done += n;
    }
    _ = try check(linux.fsync(fd));
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        off += try check(linux.write(fd, bytes[off..].ptr, bytes.len - off));
    }
}

pub fn rename(old_path: []const u8, new_path: []const u8) Error!void {
    const old_z = posix.toPosixPath(old_path) catch return error.NameTooLong;
    const new_z = posix.toPosixPath(new_path) catch return error.NameTooLong;
    _ = try check(linux.renameat(linux.AT.FDCWD, &old_z, linux.AT.FDCWD, &new_z));
}

pub fn unlink(path: []const u8) Error!void {
    const path_z = posix.toPosixPath(path) catch return error.NameTooLong;
    _ = try check(linux.unlink(&path_z));
}

pub fn exists(path: []const u8) bool {
    var buf: [0]u8 = undefined;
    _ = readFileBounded(path, &buf) catch |err| return err == error.FileTooBig;
    return true; // empty file
}

/// stat-based existence check: works for sockets and other non-openable
/// nodes, unlike exists() which open()s (a unix socket open()s to ENXIO).
pub fn pathExists(path: []const u8) bool {
    const path_z = posix.toPosixPath(path) catch return false;
    var stx: linux.Statx = undefined;
    return linux.errno(linux.statx(linux.AT.FDCWD, &path_z, 0, .{}, &stx)) == .SUCCESS;
}

/// Unique /tmp path for tests (std.testing.tmpDir now requires an Io
/// instance and its Dir has no path accessor, so path-based code under
/// test gets real /tmp names instead).
pub fn testTmpPath(buf: []u8, comptime suffix: []const u8) []const u8 {
    var rand: [8]u8 = undefined;
    _ = linux.getrandom(&rand, rand.len, 0);
    const n = std.mem.readInt(u64, &rand, .little);
    return std.fmt.bufPrint(buf, "/tmp/cragd-test-{x}-" ++ suffix, .{n}) catch unreachable;
}

test "write, read back, rename, unlink round-trip" {
    const allocator = std.testing.allocator;
    var pb1: [128]u8 = undefined;
    var pb2: [128]u8 = undefined;
    const p1 = testTmpPath(&pb1, "a.txt");
    const p2 = testTmpPath(&pb2, "b.txt");
    defer unlink(p2) catch {};

    try writeFileSync(p1, "hello fsutil");
    const back = try readFileAlloc(allocator, p1, 1024);
    defer allocator.free(back);
    try std.testing.expectEqualStrings("hello fsutil", back);

    try rename(p1, p2);
    try std.testing.expect(!exists(p1));
    try std.testing.expect(exists(p2));

    var small: [5]u8 = undefined;
    try std.testing.expectError(error.FileTooBig, readFileBounded(p2, &small));
    var big: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello fsutil", try readFileBounded(p2, &big));
}

test "missing files surface FileNotFound" {
    try std.testing.expectError(error.FileNotFound, readFileAlloc(std.testing.allocator, "/nonexistent/x", 10));
    try std.testing.expect(!exists("/nonexistent/x"));
    try std.testing.expect(!pathExists("/nonexistent/x"));
    try std.testing.expect(pathExists("/tmp"));
}
