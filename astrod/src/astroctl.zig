//! astroctl: operator CLI, a thin client over astrod's API via the unix
//! socket (docs/06 §3, §8). Multi-call: same binary, selected by argv[0]
//! basename or a leading "ctl" arg (main.zig dispatches here).
//!
//! Command groups: system/reboot/poweroff (phase 1), update */events
//! (phase 2 — docs/05 §5.1 API-driven workflow: install returns 202 + an
//! operation which this CLI polls to a terminal state, so scripts get the
//! whole install as one exit code).
//!
//! Exit codes: 0 success, 1 API/transport/operation error (problem
//! title+detail on stderr), 2 usage error.
//!
//! Test discipline: under `zig build test` the 0.16 test runner speaks its
//! build-runner protocol over the test binary's stdio, so every fd-1/2
//! write lives in run()/execute()-level functions, outside the tested pure
//! parse/format layer below.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const sync = @import("sync.zig");

pub const default_socket_path = "/run/astro/astrod.sock";

// astrod responses are small JSON documents; anything larger means we are
// not actually talking to astrod.
const max_response_len = 256 * 1024;

/// Interval between GET /operations/{id} polls while waiting for an
/// install to finish (each poll is one short-lived connection).
pub const poll_interval_ms: u64 = 1000;

/// Drain-mode `events`: exit once the stream has been quiet this long.
pub const events_quiet_ms: i32 = 2000;

const usage_text =
    \\astroctl — Astro device control (thin client over astrod's API)
    \\
    \\Usage: astroctl [--socket=PATH] <command>
    \\
    \\Commands:
    \\  system                     Show system summary (GET /api/v1/system)
    \\  reboot                     Reboot the device (POST /api/v1/system/reboot)
    \\  poweroff                   Power off the device (POST /api/v1/system/poweroff)
    \\  update status              Show RAUC slot status (GET /api/v1/update/status)
    \\  update install <file|url>  Install a bundle (local file: streamed upload;
    \\                             http(s) URL: server-side streamed install), then
    \\                             poll the operation to completion
    \\  update apply               Reboot into the newly primary slot
    \\  update rollback            Mark booted slot bad, boot the other slot
    \\  events                     Print events (full ring replay), exit when the
    \\                             stream goes quiet
    \\  help                       Show this help
    \\
    \\  ("system reboot" / "system poweroff" are accepted aliases)
    \\
    \\Options:
    \\  --socket=PATH     astrod unix socket (default /run/astro/astrod.sock)
    \\  --force           update install: bypass the AD-021 downgrade gate
    \\  --follow          events: keep the stream open (live tail) instead of
    \\                    exiting at the first quiet period
    \\
    \\Exit codes: 0 success, 1 API/operation error, 2 usage error
    \\
;

// ---- command parsing (pure, tested) ----------------------------------------

pub const Action = enum {
    show_system,
    reboot,
    poweroff,
    update_status,
    update_install,
    update_apply,
    update_rollback,
    events,
};

pub const Invocation = struct {
    action: Action,
    /// Slices into argv, which outlives the invocation.
    socket_path: []const u8 = default_socket_path,
    /// update install: local bundle path or http(s) URL.
    target: []const u8 = "",
    /// events: keep streaming instead of drain-and-exit.
    follow: bool = false,
    /// update install: AD-021 downgrade-gate override.
    force: bool = false,
};

pub const Parsed = union(enum) { help, usage_error, invoke: Invocation };

/// `args` excludes the program name (and the "ctl" selector when invoked
/// as `astrod ctl ...`). Flags may appear before or after command words.
pub fn parseCommand(args: []const []const u8) Parsed {
    var socket_path: []const u8 = default_socket_path;
    var follow = false;
    var force = false;
    var words: [3][]const u8 = undefined;
    var nwords: usize = 0;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--socket=")) {
            socket_path = arg["--socket=".len..];
            if (socket_path.len == 0) return .usage_error;
        } else if (std.mem.eql(u8, arg, "--follow")) {
            follow = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
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
    var target: []const u8 = "";
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
        else if (std.mem.eql(u8, words[0], "events"))
            .events
        else
            return .usage_error,
        2 => if (std.mem.eql(u8, words[0], "system") and std.mem.eql(u8, words[1], "reboot"))
            .reboot
        else if (std.mem.eql(u8, words[0], "system") and std.mem.eql(u8, words[1], "poweroff"))
            .poweroff
        else if (std.mem.eql(u8, words[0], "update") and std.mem.eql(u8, words[1], "status"))
            .update_status
        else if (std.mem.eql(u8, words[0], "update") and std.mem.eql(u8, words[1], "apply"))
            .update_apply
        else if (std.mem.eql(u8, words[0], "update") and std.mem.eql(u8, words[1], "rollback"))
            .update_rollback
        else
            // Includes "update install" with no target: a usage error.
            return .usage_error,
        3 => blk: {
            if (std.mem.eql(u8, words[0], "update") and std.mem.eql(u8, words[1], "install")) {
                target = words[2];
                break :blk .update_install;
            }
            return .usage_error;
        },
        else => unreachable,
    };
    // Flag applicability: rejecting a misplaced flag surfaces operator
    // typos instead of silently ignoring intent.
    if (follow and action != .events) return .usage_error;
    if (force and action != .update_install) return .usage_error;
    return .{ .invoke = .{
        .action = action,
        .socket_path = socket_path,
        .target = target,
        .follow = follow,
        .force = force,
    } };
}

/// Pure exit-code classification of an argv, kept separate from run() so
/// tests never touch stdio: 0 = help or a valid command, 2 = usage error.
pub fn evaluate(args: []const []const u8) u8 {
    return switch (parseCommand(args)) {
        .usage_error => 2,
        .help, .invoke => 0,
    };
}

/// update install target classification: http(s) targets become JSON
/// {"url": ...} installs, everything else is treated as a local file path
/// and stream-uploaded.
pub fn isUrl(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://");
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
    // Arena: a CLI invocation is one bounded exchange (the install poll
    // loop allocates a few KiB per second — fine for minutes of install);
    // everything dies here.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    return switch (inv.action) {
        .update_install => updateInstall(arena, inv),
        .events => eventsCommand(arena, inv),
        else => simpleRequest(arena, inv),
    };
}

/// One request, one response, one formatter — every command that is not
/// install (upload/poll) or events (stream).
fn simpleRequest(arena: std.mem.Allocator, inv: Invocation) u8 {
    const raw = exchange(arena, inv.socket_path, requestFor(inv.action)) catch |err|
        return transportFail(arena, inv.socket_path, err);
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
        .update_status => formatUpdateStatus(arena, resp.body) catch resp.body,
        .update_apply => formatPowerResult(arena, "apply", resp.body) catch "apply accepted\n",
        .update_rollback => formatPowerResult(arena, "rollback", resp.body) catch "rollback accepted\n",
        .update_install, .events => unreachable,
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
        .update_status => "GET /api/v1/update/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .update_apply => "POST /api/v1/update/apply HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .update_rollback => "POST /api/v1/update/rollback HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .update_install, .events => unreachable,
    };
}

// ---- update install: POST + operation poll ----------------------------------

fn updateInstall(arena: std.mem.Allocator, inv: Invocation) u8 {
    const raw = blk: {
        if (isUrl(inv.target)) {
            // JSON form: astrod hands the URL to RAUC, which streams the
            // verity bundle itself (docs/05 §3) — nothing to upload.
            const body = std.json.Stringify.valueAlloc(arena, .{ .url = inv.target, .force = inv.force }, .{}) catch return oom();
            const req = std.fmt.allocPrint(
                arena,
                "POST /api/v1/update HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ body.len, body },
            ) catch return oom();
            break :blk exchange(arena, inv.socket_path, req) catch |err|
                return transportFail(arena, inv.socket_path, err);
        }
        break :blk uploadBundle(arena, inv) catch |err| switch (err) {
            error.BundleNotFound => {
                const msg = std.fmt.allocPrint(arena, "astroctl: cannot open bundle {s}\n", .{inv.target}) catch "astroctl: cannot open bundle\n";
                writeAll(posix.STDERR_FILENO, msg);
                return 1;
            },
            else => return transportFail(arena, inv.socket_path, err),
        };
    };
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "astroctl: malformed HTTP response from astrod\n");
        return 1;
    };
    if (resp.status != 202) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "astroctl: install request failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    const op_url = parseOperationRef(arena, resp.body) catch {
        writeAll(posix.STDERR_FILENO, "astroctl: 202 response without an operation URL\n");
        return 1;
    };
    const started = std.fmt.allocPrint(arena, "installing; operation {s}\n", .{op_url}) catch return oom();
    writeAll(posix.STDOUT_FILENO, started);
    return pollOperation(arena, inv.socket_path, op_url);
}

/// Stream a local bundle file as the application/octet-stream install form.
/// Chunked file->socket copy: bundles are far larger than the CLI's memory
/// appetite, so the whole file is never resident.
fn uploadBundle(arena: std.mem.Allocator, inv: Invocation) UploadError![]u8 {
    // Open + size the file first so a bad path fails before the socket.
    const path_z = posix.toPosixPath(inv.target) catch return error.NameTooLong;
    const open_rc = linux.openat(linux.AT.FDCWD, &path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return error.BundleNotFound;
    const file_fd: posix.fd_t = @intCast(open_rc);
    defer _ = linux.close(file_fd);

    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(file_fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx)) != .SUCCESS)
        return error.BundleNotFound;
    const size: u64 = stx.size;

    // AD-021 force travels as a query parameter on the binary form (the
    // spec documents it; the octet-stream body has no room for JSON).
    const target: []const u8 = if (inv.force) "/api/v1/update?force=true" else "/api/v1/update";
    const head = std.fmt.allocPrint(
        arena,
        "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ target, size },
    ) catch return error.OutOfMemory;

    const sock = try connectUnix(inv.socket_path);
    defer _ = linux.close(sock);
    try writeAllFd(sock, head);

    var buf: [64 * 1024]u8 = undefined;
    var sent: u64 = 0;
    var send_failed = false;
    while (sent < size) {
        const n = posix.read(file_fd, &buf) catch return error.InputOutput;
        // File shrank under us: stop; the server sees a short body and
        // fails the request, which is the correct outcome.
        if (n == 0) break;
        // A body-write failure (EPIPE) usually means the server already
        // answered (401/503/507/...) and closed its read side — fall
        // through and READ that response instead of reporting a bogus
        // transport error that would hide it.
        writeAllFd(sock, buf[0..n]) catch {
            send_failed = true;
            break;
        };
        sent += n;
    }

    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(arena);
    while (true) {
        const n = posix.read(sock, &buf) catch break;
        if (n == 0) break;
        if (data.items.len + n > max_response_len) return error.ResponseTooLarge;
        try data.appendSlice(arena, buf[0..n]);
    }
    // Nothing came back AND the upload broke: a genuine transport error.
    if (data.items.len == 0 and send_failed) return error.InputOutput;
    return data.toOwnedSlice(arena);
}

/// Poll one operation to a terminal state, printing progress transitions.
/// Exit code is the operation outcome: 0 succeeded, 1 failed/unreachable.
fn pollOperation(arena: std.mem.Allocator, socket_path: []const u8, op_url: []const u8) u8 {
    const req = std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{op_url}) catch return oom();
    var last_progress: i64 = -1;
    var last_message: []const u8 = "";
    while (true) {
        const raw = exchange(arena, socket_path, req) catch |err|
            return transportFail(arena, socket_path, err);
        const resp = parseResponse(raw) catch {
            writeAll(posix.STDERR_FILENO, "astroctl: malformed HTTP response from astrod\n");
            return 1;
        };
        if (resp.status != 200) {
            const msg = formatProblem(arena, resp.status, resp.body) catch "astroctl: operation poll failed\n";
            writeAll(posix.STDERR_FILENO, msg);
            return 1;
        }
        const op = parseOperation(arena, resp.body) catch {
            writeAll(posix.STDERR_FILENO, "astroctl: malformed operation document\n");
            return 1;
        };
        if (op.progress != last_progress or !std.mem.eql(u8, op.message, last_message)) {
            const line = std.fmt.allocPrint(arena, "[{d:>3}%] {s}\n", .{ op.progress, op.message }) catch return oom();
            writeAll(posix.STDOUT_FILENO, line);
            last_progress = op.progress;
            last_message = op.message;
        }
        if (std.mem.eql(u8, op.state, "succeeded")) {
            writeAll(posix.STDOUT_FILENO, "install operation succeeded\n");
            return 0;
        }
        if (std.mem.eql(u8, op.state, "failed")) {
            const msg = std.fmt.allocPrint(arena, "error: install operation failed: {s}\n", .{op.err orelse "(no detail)"}) catch "error: install operation failed\n";
            writeAll(posix.STDERR_FILENO, msg);
            return 1;
        }
        sync.sleepMs(poll_interval_ms);
    }
}

// ---- events: SSE reader -----------------------------------------------------

// Design choice (documented): `astroctl events` always requests a FULL
// ring replay (Last-Event-ID: 0) so recently published events are visible
// without having subscribed beforehand. The default mode then exits once
// the stream is quiet for events_quiet_ms — that makes it usable from
// scripts and gates ("did an update.progress event happen?") without
// hanging; --follow keeps the connection and tails live events until
// EOF/interrupt.
fn eventsCommand(arena: std.mem.Allocator, inv: Invocation) u8 {
    const fd = connectUnix(inv.socket_path) catch |err|
        return transportFail(arena, inv.socket_path, err);
    defer _ = linux.close(fd);
    const req = "GET /api/v1/events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\nLast-Event-ID: 0\r\nConnection: close\r\n\r\n";
    writeAllFd(fd, req) catch |err| return transportFail(arena, inv.socket_path, err);

    // Read the response head; a non-200 carries a problem body instead of
    // a stream (server closes after it, so read-to-EOF completes it).
    var buf: [4096]u8 = undefined;
    var head: std.ArrayList(u8) = .empty;
    const head_end = while (true) {
        const n = posix.read(fd, &buf) catch {
            writeAll(posix.STDERR_FILENO, "astroctl: read error on event stream\n");
            return 1;
        };
        if (n == 0) {
            writeAll(posix.STDERR_FILENO, "astroctl: connection closed before a response arrived\n");
            return 1;
        }
        head.appendSlice(arena, buf[0..n]) catch return oom();
        if (std.mem.indexOf(u8, head.items, "\r\n\r\n")) |i| break i + 4;
        if (head.items.len > max_response_len) {
            writeAll(posix.STDERR_FILENO, "astroctl: oversized response head\n");
            return 1;
        }
    };
    const status = statusOf(head.items) catch {
        writeAll(posix.STDERR_FILENO, "astroctl: malformed HTTP response from astrod\n");
        return 1;
    };
    if (status != 200) {
        while (true) {
            const n = posix.read(fd, &buf) catch break;
            if (n == 0) break;
            if (head.items.len + n > max_response_len) break;
            head.appendSlice(arena, buf[0..n]) catch return oom();
        }
        const resp = parseResponse(head.items) catch {
            writeAll(posix.STDERR_FILENO, "astroctl: malformed HTTP response from astrod\n");
            return 1;
        };
        const msg = formatProblem(arena, resp.status, resp.body) catch "astroctl: event stream refused\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }

    var renderer: SseRenderer = .{};
    var lines: std.ArrayList(u8) = .empty;
    renderer.feed(arena, head.items[head_end..], &lines) catch return oom();
    writeAll(posix.STDOUT_FILENO, lines.items);
    lines.clearRetainingCapacity();

    while (true) {
        var pfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const timeout: i32 = if (inv.follow) -1 else events_quiet_ms;
        const ready = posix.poll(&pfds, timeout) catch {
            writeAll(posix.STDERR_FILENO, "astroctl: poll error on event stream\n");
            return 1;
        };
        if (ready == 0) return 0; // drain mode: quiet period reached
        const n = posix.read(fd, &buf) catch {
            writeAll(posix.STDERR_FILENO, "astroctl: read error on event stream\n");
            return 1;
        };
        if (n == 0) return 0; // server closed (shutdown, or overflow drop)
        renderer.feed(arena, buf[0..n], &lines) catch return oom();
        writeAll(posix.STDOUT_FILENO, lines.items);
        lines.clearRetainingCapacity();
    }
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
    const status = try parseStatusLine(status_line);

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

fn parseStatusLine(status_line: []const u8) ResponseError!u16 {
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    const version = parts.next() orelse return error.BadResponse;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadResponse;
    const status_str = parts.next() orelse return error.BadResponse;
    return std.fmt.parseInt(u16, status_str, 10) catch error.BadResponse;
}

/// Status of a response whose head has arrived but whose body may still be
/// streaming (the SSE path needs a verdict before EOF).
pub fn statusOf(buf: []const u8) ResponseError!u16 {
    const line_end = std.mem.indexOf(u8, buf, "\r\n") orelse return error.BadResponse;
    return parseStatusLine(buf[0..line_end]);
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

/// 202 body of POST /api/v1/update: {"operation": "/api/v1/operations/op-N"}
/// (spec OperationRef). Returns the operation path duped into `allocator`.
pub fn parseOperationRef(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const op = parsed.value.object.get("operation") orelse return error.BadResponse;
    if (op != .string or op.string.len == 0) return error.BadResponse;
    return try allocator.dupe(u8, op.string);
}

/// The Operation-document fields the poll loop consumes.
pub const OperationView = struct {
    state: []const u8,
    progress: i64,
    message: []const u8,
    err: ?[]const u8,
};

/// Parse an Operation document (spec components.schemas.Operation). All
/// strings are duped into `allocator` — pass an arena; the view outlives
/// the parse tree.
pub fn parseOperation(allocator: std.mem.Allocator, body: []const u8) !OperationView {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const obj = parsed.value.object;

    const state_v = obj.get("state") orelse return error.BadResponse;
    if (state_v != .string) return error.BadResponse;
    const progress: i64 = if (obj.get("progress")) |p| switch (p) {
        .integer => |n| n,
        else => 0,
    } else 0;
    const message: []const u8 = if (obj.get("message")) |m| switch (m) {
        .string => |s| s,
        else => "",
    } else "";
    const err_detail: ?[]const u8 = if (obj.get("error")) |e| switch (e) {
        .string => |s| s,
        else => null,
    } else null;

    return .{
        .state = try allocator.dupe(u8, state_v.string),
        .progress = progress,
        .message = try allocator.dupe(u8, message),
        .err = if (err_detail) |d| try allocator.dupe(u8, d) else null,
    };
}

/// Pretty-print GET /api/v1/update/status (spec UpdateStatus): scalar
/// header lines, then an aligned slot table. Pass an arena — intermediate
/// cell strings are not individually freed.
pub fn formatUpdateStatus(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const obj = parsed.value.object;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const scalar_keys = [_][]const u8{ "boot_slot", "primary", "operation", "compatible", "last_error" };
    for (scalar_keys) |key| {
        const value: []const u8 = if (obj.get(key)) |v| switch (v) {
            .string => |s| if (s.len == 0) "-" else s,
            else => "-",
        } else "-";
        const line = try std.fmt.allocPrint(allocator, "{s:<12} {s}\n", .{ key, value });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    if (obj.get("slots")) |slots_v| {
        if (slots_v == .array) {
            const headers = [_][]const u8{ "SLOT", "STATE", "VERSION", "BOOT", "ATTEMPTS", "DEVICE" };
            const keys = [_][]const u8{ "name", "state", "bundle_version", "boot_status", "boot_attempts_left", "device" };

            var rows: std.ArrayList([6][]const u8) = .empty;
            defer rows.deinit(allocator);
            for (slots_v.array.items) |slot_v| {
                if (slot_v != .object) continue;
                var row: [6][]const u8 = undefined;
                for (keys, 0..) |k, i| {
                    row[i] = if (slot_v.object.get(k)) |v| switch (v) {
                        .string => |s| if (s.len == 0) "-" else s,
                        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
                        else => "-",
                    } else "-";
                }
                try rows.append(allocator, row);
            }

            var widths: [6]usize = undefined;
            for (headers, 0..) |h, i| widths[i] = h.len;
            for (rows.items) |row| {
                for (row, 0..) |cell, i| widths[i] = @max(widths[i], cell.len);
            }
            try out.appendSlice(allocator, "\n");
            try appendRow(allocator, &out, headers, widths);
            for (rows.items) |row| try appendRow(allocator, &out, row, widths);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendRow(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cells: [6][]const u8, widths: [6]usize) !void {
    for (cells, 0..) |cell, i| {
        try out.appendSlice(allocator, cell);
        if (i + 1 < cells.len) {
            var pad = widths[i] - cell.len + 2;
            while (pad > 0) : (pad -= 1) try out.append(allocator, ' ');
        }
    }
    try out.append(allocator, '\n');
}

/// Incremental SSE frame renderer: feed() consumes raw stream bytes and,
/// per completed frame, appends one "[<id>] <event> <data>" line to `out`.
/// Comment lines (keepalives) are dropped; a missing id renders as "-",
/// a missing event name as the SSE default "message". Grows only inside
/// the caller's allocator — pass an arena (nothing is deinit-ed).
pub const SseRenderer = struct {
    line: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    seen_field: bool = false,

    pub fn feed(self: *SseRenderer, allocator: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        for (bytes) |b| switch (b) {
            '\r' => {},
            '\n' => try self.endLine(allocator, out),
            else => try self.line.append(allocator, b),
        };
    }

    fn endLine(self: *SseRenderer, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        const l = self.line.items;
        defer self.line.clearRetainingCapacity();
        if (l.len == 0) {
            // Frame boundary: emit if any field arrived (a lone blank line
            // between keepalives is not a frame).
            if (self.seen_field) {
                try out.append(allocator, '[');
                try out.appendSlice(allocator, if (self.id.items.len > 0) self.id.items else "-");
                try out.appendSlice(allocator, "] ");
                try out.appendSlice(allocator, if (self.event.items.len > 0) self.event.items else "message");
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, self.data.items);
                try out.append(allocator, '\n');
            }
            self.id.clearRetainingCapacity();
            self.event.clearRetainingCapacity();
            self.data.clearRetainingCapacity();
            self.seen_field = false;
            return;
        }
        if (l[0] == ':') return; // SSE comment (keepalive)
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse l.len;
        const name = l[0..colon];
        var value = l[@min(colon + 1, l.len)..];
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        self.seen_field = true;
        if (std.mem.eql(u8, name, "id")) {
            self.id.clearRetainingCapacity();
            try self.id.appendSlice(allocator, value);
        } else if (std.mem.eql(u8, name, "event")) {
            self.event.clearRetainingCapacity();
            try self.event.appendSlice(allocator, value);
        } else if (std.mem.eql(u8, name, "data")) {
            // Multi-line data joins with '\n' per the SSE spec.
            if (self.data.items.len > 0) try self.data.append(allocator, '\n');
            try self.data.appendSlice(allocator, value);
        }
        // Unknown fields are ignored per the SSE spec.
    }
};

// ---- transport (raw syscalls, same rationale as main.zig) ------------------

const TransportError = error{ FileNotFound, ConnectionRefused, AccessDenied, NameTooLong, ResponseTooLarge, InputOutput, Unexpected, OutOfMemory };

/// uploadBundle only: BundleNotFound distinguishes "the bundle file is
/// missing/unreadable" from a FileNotFound on the daemon socket, so the
/// operator gets the right message.
const UploadError = TransportError || error{BundleNotFound};

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

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) TransportError!void {
    var off: usize = 0;
    while (off < bytes.len) {
        off += try check(linux.write(fd, bytes[off..].ptr, bytes.len - off));
    }
}

/// One request/response over the unix socket; Connection: close means
/// read-to-EOF delimits the response.
fn exchange(allocator: std.mem.Allocator, socket_path: []const u8, request: []const u8) TransportError![]u8 {
    const fd = try connectUnix(socket_path);
    defer _ = linux.close(fd);

    try writeAllFd(fd, request);

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

fn transportFail(arena: std.mem.Allocator, socket_path: []const u8, err: anyerror) u8 {
    const msg = std.fmt.allocPrint(arena, "astroctl: cannot reach astrod at {s} ({t}) — is astrod running?\n", .{ socket_path, err }) catch "astroctl: cannot reach astrod\n";
    writeAll(posix.STDERR_FILENO, msg);
    return 1;
}

fn oom() u8 {
    writeAll(posix.STDERR_FILENO, "astroctl: out of memory\n");
    return 1;
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

test "parseCommand: update command group" {
    const st = parseCommand(&.{ "update", "status" });
    try std.testing.expectEqual(Action.update_status, st.invoke.action);

    const ap = parseCommand(&.{ "update", "apply" });
    try std.testing.expectEqual(Action.update_apply, ap.invoke.action);

    const rb = parseCommand(&.{ "update", "rollback" });
    try std.testing.expectEqual(Action.update_rollback, rb.invoke.action);

    const inst = parseCommand(&.{ "update", "install", "/data/update.raucb" });
    try std.testing.expectEqual(Action.update_install, inst.invoke.action);
    try std.testing.expectEqualStrings("/data/update.raucb", inst.invoke.target);
    try std.testing.expect(!inst.invoke.force);

    // --force is free-order and install-only.
    const forced = parseCommand(&.{ "update", "install", "--force", "https://example.com/astro.raucb" });
    try std.testing.expectEqual(Action.update_install, forced.invoke.action);
    try std.testing.expectEqualStrings("https://example.com/astro.raucb", forced.invoke.target);
    try std.testing.expect(forced.invoke.force);

    // install without a target is a usage error, not a partial command.
    try std.testing.expect(parseCommand(&.{ "update", "install" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "update", "frobnicate" }) == .usage_error);
}

test "parseCommand: events and flag applicability" {
    const ev = parseCommand(&.{"events"});
    try std.testing.expectEqual(Action.events, ev.invoke.action);
    try std.testing.expect(!ev.invoke.follow);

    const follow = parseCommand(&.{ "events", "--follow" });
    try std.testing.expectEqual(Action.events, follow.invoke.action);
    try std.testing.expect(follow.invoke.follow);

    // Misplaced flags are usage errors, not silently ignored intent.
    try std.testing.expect(parseCommand(&.{ "update", "status", "--force" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "update", "install", "/x.raucb", "--follow" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "system", "--follow" }) == .usage_error);
}

test "parseCommand and evaluate flag usage errors" {
    try std.testing.expect(parseCommand(&.{"frobnicate"}) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "system", "frobnicate" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "system", "reboot", "now" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{"--socket="}) == .usage_error);
    try std.testing.expect(parseCommand(&.{"--bogus"}) == .usage_error);

    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{}));
    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{"system"}));
    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{ "update", "status" }));
    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{ "update", "install", "/a.raucb" }));
    try std.testing.expectEqual(@as(u8, 2), evaluate(&.{ "update", "install" }));
    try std.testing.expectEqual(@as(u8, 2), evaluate(&.{"frobnicate"}));
}

test "isUrl classifies install targets" {
    try std.testing.expect(isUrl("http://example.com/a.raucb"));
    try std.testing.expect(isUrl("https://example.com/a.raucb"));
    try std.testing.expect(!isUrl("/data/update.raucb"));
    try std.testing.expect(!isUrl("update.raucb"));
    try std.testing.expect(!isUrl("httpx://nope"));
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

test "statusOf reads the status from a head-only buffer" {
    try std.testing.expectEqual(@as(u16, 200), try statusOf("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"));
    try std.testing.expectError(error.BadResponse, statusOf("no crlf yet"));
    try std.testing.expectError(error.BadResponse, statusOf("SPDY/1 200\r\n"));
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

test "parseOperationRef extracts the operation path, rejects null/missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try parseOperationRef(arena, "{\"operation\":\"/api/v1/operations/op-3\"}");
    try std.testing.expectEqualStrings("/api/v1/operations/op-3", url);

    try std.testing.expectError(error.BadResponse, parseOperationRef(arena, "{\"operation\":null}"));
    try std.testing.expectError(error.BadResponse, parseOperationRef(arena, "{}"));
    try std.testing.expectError(error.BadResponse, parseOperationRef(arena, "[]"));
}

test "parseOperation: running, failed, and defaulted fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const running = try parseOperation(arena,
        \\{"id":"op-1","kind":"update_install","state":"running","progress":42,"message":"Copying image","error":null}
    );
    try std.testing.expectEqualStrings("running", running.state);
    try std.testing.expectEqual(@as(i64, 42), running.progress);
    try std.testing.expectEqualStrings("Copying image", running.message);
    try std.testing.expectEqual(@as(?[]const u8, null), running.err);

    const failed = try parseOperation(arena,
        \\{"id":"op-2","kind":"update_install","state":"failed","progress":80,"message":"Installing","error":"bundle version 0.0.9 is lower than running 1.0.0"}
    );
    try std.testing.expectEqualStrings("failed", failed.state);
    try std.testing.expectEqualStrings("bundle version 0.0.9 is lower than running 1.0.0", failed.err.?);

    // Missing optional fields default; a missing state is a bad document.
    const minimal = try parseOperation(arena, "{\"state\":\"pending\"}");
    try std.testing.expectEqualStrings("pending", minimal.state);
    try std.testing.expectEqual(@as(i64, 0), minimal.progress);
    try std.testing.expectEqualStrings("", minimal.message);
    try std.testing.expectError(error.BadResponse, parseOperation(arena, "{\"progress\":10}"));
}

test "formatUpdateStatus renders scalars and an aligned slot table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"boot_slot":"A","primary":"rootfs.1","operation":"idle","last_error":"","compatible":"astro-virt",
        \\ "slots":[
        \\  {"name":"rootfs.0","state":"booted","bundle_version":"0.0.0-dev","boot_status":"good","boot_attempts_left":3,"device":"/dev/vda5"},
        \\  {"name":"rootfs.1","state":"inactive","bundle_version":"","boot_status":"good","boot_attempts_left":null,"device":"/dev/vda6"}]}
    ;
    const out = try formatUpdateStatus(arena, body);
    const expected =
        "boot_slot    A\n" ++
        "primary      rootfs.1\n" ++
        "operation    idle\n" ++
        "compatible   astro-virt\n" ++
        "last_error   -\n" ++
        "\n" ++
        "SLOT      STATE     VERSION    BOOT  ATTEMPTS  DEVICE\n" ++
        "rootfs.0  booted    0.0.0-dev  good  3         /dev/vda5\n" ++
        "rootfs.1  inactive  -          good  -         /dev/vda6\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "SseRenderer: frames across chunk boundaries, keepalives, overflow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var renderer: SseRenderer = .{};
    var out: std.ArrayList(u8) = .empty;

    // One frame split mid-line across two feeds, then a keepalive comment,
    // then an overflow frame without an id.
    try renderer.feed(arena, "id: 3\nevent: update.pro", &out);
    try std.testing.expectEqualStrings("", out.items);
    try renderer.feed(arena, "gress\ndata: {\"percentage\":40}\n\n", &out);
    try std.testing.expectEqualStrings("[3] update.progress {\"percentage\":40}\n", out.items);

    out.clearRetainingCapacity();
    try renderer.feed(arena, ": keepalive\n\n", &out);
    try std.testing.expectEqualStrings("", out.items);

    try renderer.feed(arena, "event: overflow\ndata: {\"dropped\":true}\n\n", &out);
    try std.testing.expectEqualStrings("[-] overflow {\"dropped\":true}\n", out.items);

    // Default event name per SSE, and CRLF tolerance.
    out.clearRetainingCapacity();
    try renderer.feed(arena, "id: 9\r\ndata: {}\r\n\r\n", &out);
    try std.testing.expectEqualStrings("[9] message {}\n", out.items);
}
