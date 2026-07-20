//! astroctl: operator CLI, a thin client over astrod's API via the unix
//! socket (docs/06 §3, §8). Multi-call: same binary, selected by argv[0]
//! basename or a leading "ctl" arg (main.zig dispatches here).
//!
//! Exit codes: 0 success, 1 API/transport error (problem title+detail on
//! stderr), 2 usage error.
//!
//! Test discipline: under `zig build test` the 0.16 test runner speaks its
//! build-runner protocol over the test binary's stdio, so every fd-1/2
//! write lives in run()/execute(), outside the tested pure parse/format
//! layer below.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const default_socket_path = "/run/astro/astrod.sock";

// astrod responses are small JSON documents; anything larger means we are
// not actually talking to astrod.
const max_response_len = 256 * 1024;

const usage_text =
    \\astroctl — Astro device control (thin client over astrod's API)
    \\
    \\Usage: astroctl [--socket=PATH] <command>
    \\
    \\Commands:
    \\  system            Show system summary (GET /api/v1/system)
    \\  reboot            Reboot the device (POST /api/v1/system/reboot)
    \\  poweroff          Power off the device (POST /api/v1/system/poweroff)
    \\  help              Show this help
    \\
    \\  ("system reboot" / "system poweroff" are accepted aliases)
    \\
    \\Options:
    \\  --socket=PATH     astrod unix socket (default /run/astro/astrod.sock)
    \\
    \\Exit codes: 0 success, 1 API error, 2 usage error
    \\
;

// ---- command parsing (pure, tested) ----------------------------------------

pub const Action = enum { show_system, reboot, poweroff };

pub const Invocation = struct {
    action: Action,
    /// Slices into argv, which outlives the invocation.
    socket_path: []const u8 = default_socket_path,
};

pub const Parsed = union(enum) { help, usage_error, invoke: Invocation };

/// `args` excludes the program name (and the "ctl" selector when invoked
/// as `astrod ctl ...`). Flags may appear before or after command words.
pub fn parseCommand(args: []const []const u8) Parsed {
    var socket_path: []const u8 = default_socket_path;
    var words: [2][]const u8 = undefined;
    var nwords: usize = 0;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--socket=")) {
            socket_path = arg["--socket=".len..];
            if (socket_path.len == 0) return .usage_error;
        } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return .usage_error;
        } else {
            if (nwords == words.len) return .usage_error;
            words[nwords] = arg;
            nwords += 1;
        }
    }
    const action: Action = switch (nwords) {
        // Bare `astroctl` prints usage as help (exit 0), not as an error:
        // the discovery path for operators.
        0 => return .help,
        1 => if (std.mem.eql(u8, words[0], "system"))
            .show_system
        else if (std.mem.eql(u8, words[0], "reboot"))
            .reboot
        else if (std.mem.eql(u8, words[0], "poweroff"))
            .poweroff
        else
            return .usage_error,
        2 => if (std.mem.eql(u8, words[0], "system") and std.mem.eql(u8, words[1], "reboot"))
            .reboot
        else if (std.mem.eql(u8, words[0], "system") and std.mem.eql(u8, words[1], "poweroff"))
            .poweroff
        else
            return .usage_error,
        else => unreachable,
    };
    return .{ .invoke = .{ .action = action, .socket_path = socket_path } };
}

/// Pure exit-code classification of an argv, kept separate from run() so
/// tests never touch stdio: 0 = help or a valid command, 2 = usage error.
pub fn evaluate(args: []const []const u8) u8 {
    return switch (parseCommand(args)) {
        .usage_error => 2,
        .help, .invoke => 0,
    };
}

// ---- entry ------------------------------------------------------------------

/// Returns the process exit code.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    switch (parseCommand(args)) {
        .help => {
            writeAll(posix.STDOUT_FILENO, usage_text);
            return 0;
        },
        .usage_error => {
            writeAll(posix.STDERR_FILENO, usage_text);
            return 2;
        },
        .invoke => |inv| return execute(allocator, inv),
    }
}

fn execute(gpa: std.mem.Allocator, inv: Invocation) u8 {
    // Arena: a CLI invocation is one request/response; everything dies here.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = exchange(arena, inv.socket_path, requestFor(inv.action)) catch |err| {
        const msg = std.fmt.allocPrint(arena, "astroctl: cannot reach astrod at {s} ({t}) — is astrod running?\n", .{ inv.socket_path, err }) catch "astroctl: cannot reach astrod\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    };
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "astroctl: malformed HTTP response from astrod\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "astroctl: request failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    const out: []const u8 = switch (inv.action) {
        // On a format failure the raw body is still the truth — show it.
        .show_system => formatSystemInfo(arena, resp.body) catch resp.body,
        .reboot => formatPowerResult(arena, "reboot", resp.body) catch "reboot accepted\n",
        .poweroff => formatPowerResult(arena, "poweroff", resp.body) catch "poweroff accepted\n",
    };
    writeAll(posix.STDOUT_FILENO, out);
    return 0;
}

// Paths mirror router.zig's table, which the AD-013 conformance gate pins
// to the spec; a drift here would fail against the live daemon in the QEMU
// `test api` stage.
fn requestFor(action: Action) []const u8 {
    return switch (action) {
        .show_system => "GET /api/v1/system HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .reboot => "POST /api/v1/system/reboot HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .poweroff => "POST /api/v1/system/poweroff HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    };
}

// ---- response parsing and rendering (pure, tested) -------------------------

pub const ClientResponse = struct {
    status: u16,
    content_type: []const u8 = "",
    body: []const u8,
};

pub const ResponseError = error{BadResponse};

/// Parse a complete HTTP/1.1 response. astrod always closes after one
/// response, so `buf` is the whole stream: body runs to EOF, bounded by
/// Content-Length when present (a shorter stream than promised is an error).
pub fn parseResponse(buf: []const u8) ResponseError!ClientResponse {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.BadResponse;
    var lines = std.mem.splitSequence(u8, buf[0..head_end], "\r\n");

    const status_line = lines.next() orelse return error.BadResponse;
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    const version = parts.next() orelse return error.BadResponse;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadResponse;
    const status_str = parts.next() orelse return error.BadResponse;
    const status = std.fmt.parseInt(u16, status_str, 10) catch return error.BadResponse;

    var resp: ClientResponse = .{ .status = status, .body = buf[head_end + 4 ..] };
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            resp.content_type = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const n = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
            if (n > resp.body.len) return error.BadResponse; // truncated stream
            resp.body = resp.body[0..n];
        }
    }
    return resp;
}

/// Pretty-print a JSON object as aligned key/value lines in document order
/// (std.json preserves it). Generic over fields so new SystemInfo fields
/// need no CLI change.
pub fn formatSystemInfo(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const line = switch (entry.value_ptr.*) {
            .string => |s| try std.fmt.allocPrint(allocator, "{s:<13} {s}\n", .{ entry.key_ptr.*, s }),
            .integer => |n| try std.fmt.allocPrint(allocator, "{s:<13} {d}\n", .{ entry.key_ptr.*, n }),
            .bool => |b| try std.fmt.allocPrint(allocator, "{s:<13} {}\n", .{ entry.key_ptr.*, b }),
            else => |v| blk: {
                const rendered = try std.json.Stringify.valueAlloc(allocator, v, .{});
                defer allocator.free(rendered);
                break :blk try std.fmt.allocPrint(allocator, "{s:<13} {s}\n", .{ entry.key_ptr.*, rendered });
            },
        };
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

/// Render an error response for stderr: RFC 7807 title/detail when the
/// body is problem+json, bare HTTP status otherwise.
pub fn formatProblem(allocator: std.mem.Allocator, status: u16, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return std.fmt.allocPrint(allocator, "error: HTTP {d}\n", .{status});
    defer parsed.deinit();
    if (parsed.value != .object) return std.fmt.allocPrint(allocator, "error: HTTP {d}\n", .{status});
    const obj = parsed.value.object;

    const title: []const u8 = if (obj.get("title")) |t| switch (t) {
        .string => |s| s,
        else => "",
    } else "";
    if (title.len == 0) return std.fmt.allocPrint(allocator, "error: HTTP {d}\n", .{status});

    if (obj.get("detail")) |d| switch (d) {
        .string => |s| return std.fmt.allocPrint(allocator, "error: {s}: {s}\n", .{ title, s }),
        else => {},
    };
    return std.fmt.allocPrint(allocator, "error: {s}\n", .{title});
}

/// 202 body for power actions is {"operation": url-or-null} (spec
/// PowerActionResult); surface the operation URL when there is one.
pub fn formatPowerResult(allocator: std.mem.Allocator, action: []const u8, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return std.fmt.allocPrint(allocator, "{s} accepted\n", .{action});
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("operation")) |op| switch (op) {
            .string => |s| return std.fmt.allocPrint(allocator, "{s} accepted; operation: {s}\n", .{ action, s }),
            else => {},
        };
    }
    return std.fmt.allocPrint(allocator, "{s} accepted\n", .{action});
}

// ---- transport (raw syscalls, same rationale as main.zig) ------------------

const TransportError = error{ FileNotFound, ConnectionRefused, AccessDenied, NameTooLong, ResponseTooLarge, InputOutput, Unexpected, OutOfMemory };

// The errno cases an operator can act on get their own names for the
// "cannot reach astrod" message; the rest collapse to Unexpected.
fn check(rc: usize) TransportError!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOENT => error.FileNotFound,
        .CONNREFUSED => error.ConnectionRefused,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

fn connectUnix(path: []const u8) TransportError!posix.fd_t {
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);

    const fd: posix.fd_t = @intCast(try check(linux.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(fd);
    _ = try check(linux.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)));
    return fd;
}

/// One request/response over the unix socket; Connection: close means
/// read-to-EOF delimits the response.
fn exchange(allocator: std.mem.Allocator, socket_path: []const u8, request: []const u8) TransportError![]u8 {
    const fd = try connectUnix(socket_path);
    defer _ = linux.close(fd);

    var off: usize = 0;
    while (off < request.len) {
        off += try check(linux.write(fd, request[off..].ptr, request.len - off));
    }

    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch return error.InputOutput;
        if (n == 0) break;
        if (data.items.len + n > max_response_len) return error.ResponseTooLarge;
        try data.appendSlice(allocator, buf[0..n]);
    }
    return data.toOwnedSlice(allocator);
}

// Raw write(2): stable across the std.Io churn and astroctl output is
// tiny/unbuffered anyway.
fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS) return;
        off += rc;
    }
}

// ---- tests -----------------------------------------------------------------

test "parseCommand: help forms and empty argv" {
    try std.testing.expect(parseCommand(&.{}) == .help);
    try std.testing.expect(parseCommand(&.{"help"}) == .help);
    try std.testing.expect(parseCommand(&.{"--help"}) == .help);
    try std.testing.expect(parseCommand(&.{"-h"}) == .help);
}

test "parseCommand: commands, aliases, and socket override" {
    const sys_cmd = parseCommand(&.{"system"});
    try std.testing.expectEqual(Action.show_system, sys_cmd.invoke.action);
    try std.testing.expectEqualStrings(default_socket_path, sys_cmd.invoke.socket_path);

    const rb = parseCommand(&.{ "--socket=/tmp/x.sock", "reboot" });
    try std.testing.expectEqual(Action.reboot, rb.invoke.action);
    try std.testing.expectEqualStrings("/tmp/x.sock", rb.invoke.socket_path);

    // Flag placement is free-order; "system poweroff" aliases "poweroff".
    const po = parseCommand(&.{ "system", "poweroff", "--socket=/tmp/y.sock" });
    try std.testing.expectEqual(Action.poweroff, po.invoke.action);
    try std.testing.expectEqualStrings("/tmp/y.sock", po.invoke.socket_path);
}

test "parseCommand and evaluate flag usage errors" {
    try std.testing.expect(parseCommand(&.{"frobnicate"}) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "system", "frobnicate" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "system", "reboot", "now" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{"--socket="}) == .usage_error);
    try std.testing.expect(parseCommand(&.{"--bogus"}) == .usage_error);

    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{}));
    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{"system"}));
    try std.testing.expectEqual(@as(u8, 2), evaluate(&.{"frobnicate"}));
}

test "parseResponse extracts status, content type, and body" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";
    const resp = try parseResponse(raw);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{}", resp.body);
}

test "parseResponse honors Content-Length and rejects garbage" {
    // Body bounded by Content-Length even if the stream has trailing bytes.
    const bounded = try parseResponse("HTTP/1.1 202 Accepted\r\nContent-Length: 2\r\n\r\n{}XX");
    try std.testing.expectEqualStrings("{}", bounded.body);

    try std.testing.expectError(error.BadResponse, parseResponse("not http"));
    try std.testing.expectError(error.BadResponse, parseResponse("HTTP/1.1 xx OK\r\n\r\n"));
    // Stream shorter than the promised Content-Length is a truncated response.
    try std.testing.expectError(error.BadResponse, parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}"));
}

test "formatSystemInfo renders aligned key-value lines in document order" {
    const a = std.testing.allocator;
    const out = try formatSystemInfo(a, "{\"board\":\"qemu-aarch64\",\"uptime_s\":42}");
    defer a.free(out);
    try std.testing.expectEqualStrings("board" ++ (" " ** 9) ++ "qemu-aarch64\n" ++ "uptime_s" ++ (" " ** 6) ++ "42\n", out);
}

test "formatProblem prefers title and detail, falls back to HTTP status" {
    const a = std.testing.allocator;

    const with_detail = try formatProblem(a, 501, "{\"type\":\"urn:astro:problem:not-implemented\",\"title\":\"Not Implemented\",\"status\":501,\"detail\":\"dinit client not wired\"}");
    defer a.free(with_detail);
    try std.testing.expectEqualStrings("error: Not Implemented: dinit client not wired\n", with_detail);

    const no_detail = try formatProblem(a, 404, "{\"type\":\"urn:astro:problem:not-found\",\"title\":\"Not Found\",\"status\":404}");
    defer a.free(no_detail);
    try std.testing.expectEqualStrings("error: Not Found\n", no_detail);

    const garbage = try formatProblem(a, 500, "<html>");
    defer a.free(garbage);
    try std.testing.expectEqualStrings("error: HTTP 500\n", garbage);
}

test "formatPowerResult reports the operation URL when present" {
    const a = std.testing.allocator;

    const with_op = try formatPowerResult(a, "reboot", "{\"operation\":\"/api/v1/operations/7\"}");
    defer a.free(with_op);
    try std.testing.expectEqualStrings("reboot accepted; operation: /api/v1/operations/7\n", with_op);

    const null_op = try formatPowerResult(a, "poweroff", "{\"operation\":null}");
    defer a.free(null_op);
    try std.testing.expectEqualStrings("poweroff accepted\n", null_op);
}
