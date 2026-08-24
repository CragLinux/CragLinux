//! cragctl: operator CLI, a thin client over cragd's API via the unix
//! socket (docs/06 §3, §8). Multi-call: same binary, selected by argv[0]
//! basename or a leading "ctl" arg (main.zig dispatches here).
//!
//! Command groups: system/reboot/poweroff (phase 1), update */events
//! (phase 2 — docs/05 §5.1 API-driven workflow: install returns 202 + an
//! operation which this CLI polls to a terminal state, so scripts get the
//! whole install as one exit code), network/wifi/wan/ethernet (phase 3 —
//! docs/06 §5.2: `wifi scan` triggers the scan operation, polls it, then
//! prints the results; `wifi connect` persists the profile and polls
//! GET /network/wifi until the station state reaches "connected" —
//! the state endpoint is the authoritative view the events narrate, and
//! polling it keeps the CLI independent of event payload shapes).
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
const wifi = @import("wifi.zig");
const timekeep = @import("timekeep.zig");
const fsutil = @import("fsutil.zig");

pub const default_socket_path = "/run/crag/cragd.sock";

// cragd responses are small JSON documents; anything larger means we are
// not actually talking to cragd.
const max_response_len = 256 * 1024;

/// Interval between GET /operations/{id} polls while waiting for an
/// install to finish (each poll is one short-lived connection).
pub const poll_interval_ms: u64 = 1000;

/// Drain-mode `events`: exit once the stream has been quiet this long.
pub const events_quiet_ms: i32 = 2000;

/// `wifi connect`: how long to wait for the station state to reach
/// "connected" before giving up (overridable with --timeout=SECONDS).
pub const default_connect_timeout_s: u32 = 60;

const usage_text =
    \\cragctl — Crag device control (thin client over cragd's API)
    \\
    \\Usage: cragctl [--socket=PATH] <command>
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
    \\  network                    Interface overview + WAN order (GET /api/v1/network)
    \\  wifi scan                  Trigger a scan, wait for it, list visible networks
    \\  wifi networks              List the latest scan results
    \\  wifi connect <ssid>        Configure + connect the station profile; the
    \\                             passphrase comes from --psk= or is read from
    \\                             stdin; waits until connected (or --timeout=)
    \\  wifi forget                Forget the configured profile (disconnects)
    \\  wan get                    Show the WAN interface-class order
    \\  wan set <csv>              Replace it, e.g. `wan set ethernet,wifi`
    \\  ethernet get <iface>       Show the wired config for one interface
    \\  ethernet set <iface>       Replace it: --dhcp | --static=ADDR/PREFIX[,GW]
    \\  provision status           Provisioning state + wired/wifi observations
    \\  wifi ap show               Provisioning-AP state, incl. the derived
    \\                             SSID/PSK (label story; the PSK is derived
    \\                             locally from /etc/machine-id and is NEVER
    \\                             served over HTTP — this is the socket-only
    \\                             surface for it)
    \\  wifi ap enable             Force the provisioning AP up (persisted
    \\                             override; PUT /api/v1/network/wifi/ap)
    \\  wifi ap disable            Force the provisioning AP down
    \\  wifi ap auto               Return AP control to the provisioning
    \\                             state machine (clears the override)
    \\  factory-reset [id]         Wipe /data and reboot (docs/07 §5).
    \\                             Prompts for this device's machine-id;
    \\                             --yes-really-wipe with the machine-id as
    \\                             the argument skips the prompt (scripts)
    \\  time                       Clock status: NTP sync + build-epoch floor
    \\  help                       Show this help
    \\
    \\  ("system reboot" / "system poweroff" are accepted aliases)
    \\
    \\Options:
    \\  --socket=PATH     cragd unix socket (default /run/crag/cragd.sock)
    \\  --force           update install: bypass the AD-021 downgrade gate
    \\  --follow          events: keep the stream open (live tail) instead of
    \\                    exiting at the first quiet period
    \\  --psk=PASSPHRASE  wifi connect: WPA-PSK passphrase (omit to read a line
    \\                    from stdin — keeps the secret out of argv)
    \\  --timeout=SECONDS wifi connect: association wait bound (default 60)
    \\  --dhcp            ethernet set: IPv4 via DHCP
    \\  --static=ADDR/PREFIX[,GW]
    \\                    ethernet set: static IPv4 (gateway optional)
    \\  --yes-really-wipe factory-reset: skip the interactive confirm; the
    \\                    machine-id must be given as the positional argument
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
    network,
    wifi_scan,
    wifi_networks,
    wifi_connect,
    wifi_forget,
    wan_get,
    wan_set,
    eth_get,
    eth_set,
    provision_status,
    wifi_ap_show,
    wifi_ap_enable,
    wifi_ap_disable,
    wifi_ap_auto,
    factory_reset,
    time_status,
};

pub const Invocation = struct {
    action: Action,
    /// Slices into argv, which outlives the invocation.
    socket_path: []const u8 = default_socket_path,
    /// The positional argument: update install's bundle path/URL, wifi
    /// connect's SSID, wan set's csv order, ethernet's interface name.
    target: []const u8 = "",
    /// events: keep streaming instead of drain-and-exit.
    follow: bool = false,
    /// update install: AD-021 downgrade-gate override.
    force: bool = false,
    /// wifi connect: passphrase; null means read it from stdin.
    psk: ?[]const u8 = null,
    /// ethernet set: raw --static=ADDR/PREFIX[,GW] spec (validated at
    /// parse time so a bad spec is a usage error, not an API round trip).
    static_spec: ?[]const u8 = null,
    /// ethernet set: DHCP mode.
    dhcp: bool = false,
    /// wifi connect: association wait bound.
    timeout_s: u32 = default_connect_timeout_s,
    /// factory-reset: non-interactive confirm — requires the machine-id
    /// as the positional argument (and vice versa), so a script can never
    /// wipe a device without naming it explicitly.
    yes_really_wipe: bool = false,
};

pub const Parsed = union(enum) { help, usage_error, invoke: Invocation };

/// `args` excludes the program name (and the "ctl" selector when invoked
/// as `cragd ctl ...`). Flags may appear before or after command words.
pub fn parseCommand(args: []const []const u8) Parsed {
    var socket_path: []const u8 = default_socket_path;
    var follow = false;
    var force = false;
    var psk: ?[]const u8 = null;
    var static_spec: ?[]const u8 = null;
    var dhcp = false;
    var timeout_s: u32 = default_connect_timeout_s;
    var timeout_set = false;
    var yes_really_wipe = false;
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
        } else if (std.mem.startsWith(u8, arg, "--psk=")) {
            psk = arg["--psk=".len..];
            if (psk.?.len == 0) return .usage_error;
        } else if (std.mem.startsWith(u8, arg, "--static=")) {
            static_spec = arg["--static=".len..];
            if (static_spec.?.len == 0) return .usage_error;
        } else if (std.mem.eql(u8, arg, "--dhcp")) {
            dhcp = true;
        } else if (std.mem.eql(u8, arg, "--yes-really-wipe")) {
            yes_really_wipe = true;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_s = std.fmt.parseInt(u32, arg["--timeout=".len..], 10) catch return .usage_error;
            if (timeout_s == 0) return .usage_error;
            timeout_set = true;
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
        // Bare `cragctl` prints usage as help (exit 0), not as an error:
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
        else if (std.mem.eql(u8, words[0], "network"))
            .network
        else if (std.mem.eql(u8, words[0], "factory-reset"))
            // Interactive form: the confirm machine-id is prompted for.
            .factory_reset
        else if (std.mem.eql(u8, words[0], "time"))
            .time_status
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
        else if (std.mem.eql(u8, words[0], "wifi") and std.mem.eql(u8, words[1], "scan"))
            .wifi_scan
        else if (std.mem.eql(u8, words[0], "wifi") and std.mem.eql(u8, words[1], "networks"))
            .wifi_networks
        else if (std.mem.eql(u8, words[0], "wifi") and std.mem.eql(u8, words[1], "forget"))
            .wifi_forget
        else if (std.mem.eql(u8, words[0], "wan") and std.mem.eql(u8, words[1], "get"))
            .wan_get
        else if (std.mem.eql(u8, words[0], "provision") and std.mem.eql(u8, words[1], "status"))
            .provision_status
        else if (std.mem.eql(u8, words[0], "factory-reset")) blk: {
            // Non-interactive form: the machine-id rides as the positional
            // argument (paired with --yes-really-wipe, enforced below).
            target = words[1];
            break :blk .factory_reset;
        } else
        // Includes commands missing their positional argument
        // ("update install", "wifi connect", "wan set",
        // "ethernet get/set"): usage errors, not partial commands.
        return .usage_error,
        3 => blk: {
            if (std.mem.eql(u8, words[0], "update") and std.mem.eql(u8, words[1], "install")) {
                target = words[2];
                break :blk .update_install;
            }
            if (std.mem.eql(u8, words[0], "wifi") and std.mem.eql(u8, words[1], "connect")) {
                target = words[2];
                break :blk .wifi_connect;
            }
            if (std.mem.eql(u8, words[0], "wan") and std.mem.eql(u8, words[1], "set")) {
                target = words[2];
                break :blk .wan_set;
            }
            if (std.mem.eql(u8, words[0], "ethernet") and std.mem.eql(u8, words[1], "get")) {
                target = words[2];
                break :blk .eth_get;
            }
            if (std.mem.eql(u8, words[0], "ethernet") and std.mem.eql(u8, words[1], "set")) {
                target = words[2];
                break :blk .eth_set;
            }
            if (std.mem.eql(u8, words[0], "wifi") and std.mem.eql(u8, words[1], "ap")) {
                if (std.mem.eql(u8, words[2], "show")) break :blk .wifi_ap_show;
                if (std.mem.eql(u8, words[2], "enable")) break :blk .wifi_ap_enable;
                if (std.mem.eql(u8, words[2], "disable")) break :blk .wifi_ap_disable;
                if (std.mem.eql(u8, words[2], "auto")) break :blk .wifi_ap_auto;
                return .usage_error;
            }
            return .usage_error;
        },
        else => unreachable,
    };
    // Flag applicability: rejecting a misplaced flag surfaces operator
    // typos instead of silently ignoring intent.
    if (follow and action != .events) return .usage_error;
    if (force and action != .update_install) return .usage_error;
    if (psk != null and action != .wifi_connect) return .usage_error;
    if (timeout_set and action != .wifi_connect) return .usage_error;
    if ((static_spec != null or dhcp) and action != .eth_set) return .usage_error;
    if (yes_really_wipe and action != .factory_reset) return .usage_error;
    if (action == .factory_reset) {
        // The flag and the explicit machine-id come as a PAIR: a bare
        // --yes-really-wipe (nothing named) and a bare id (no flag) are
        // both usage errors — a scripted wipe must spell out its target,
        // and an id alone falls through to the interactive prompt never.
        if (yes_really_wipe != (target.len != 0)) return .usage_error;
    }
    if (action == .eth_set) {
        // Exactly one mode: --dhcp XOR --static=..., and the static spec
        // must parse — the API round trip should never see CLI typos.
        if (dhcp == (static_spec != null)) return .usage_error;
        if (static_spec) |spec| {
            _ = parseStaticSpec(spec) catch return .usage_error;
        }
    }
    return .{ .invoke = .{
        .action = action,
        .socket_path = socket_path,
        .target = target,
        .follow = follow,
        .force = force,
        .psk = psk,
        .static_spec = static_spec,
        .dhcp = dhcp,
        .timeout_s = timeout_s,
        .yes_really_wipe = yes_really_wipe,
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
        .wifi_scan => wifiScan(arena, inv),
        .wifi_connect => wifiConnect(arena, inv),
        .wan_set => wanSet(arena, inv),
        .eth_get, .eth_set => ethernetCommand(arena, inv),
        .provision_status => provisionStatus(arena, inv),
        .wifi_ap_show => wifiApShow(arena, inv),
        .wifi_ap_enable, .wifi_ap_disable, .wifi_ap_auto => wifiApSet(arena, inv),
        .factory_reset => factoryReset(arena, inv),
        .time_status => timeStatus(arena, inv),
        else => simpleRequest(arena, inv),
    };
}

/// One request, one response, one formatter — every command that is not
/// install (upload/poll) or events (stream).
fn simpleRequest(arena: std.mem.Allocator, inv: Invocation) u8 {
    const raw = exchange(arena, inv.socket_path, requestFor(inv.action)) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: request failed\n";
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
        .network => formatNetworkOverview(arena, resp.body) catch resp.body,
        .wifi_networks => formatWifiNetworks(arena, resp.body) catch resp.body,
        .wan_get => formatWanPolicy(arena, resp.body) catch resp.body,
        .wifi_forget => "wifi connection forgotten\n",
        .update_install, .events, .wifi_scan, .wifi_connect, .wan_set, .eth_get, .eth_set, .provision_status, .wifi_ap_show, .wifi_ap_enable, .wifi_ap_disable, .wifi_ap_auto, .factory_reset, .time_status => unreachable,
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
        .network => "GET /api/v1/network HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .wifi_networks => "GET /api/v1/network/wifi/networks HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .wifi_forget => "DELETE /api/v1/network/wifi/connection HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .wan_get => "GET /api/v1/network/wan HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .update_install, .events, .wifi_scan, .wifi_connect, .wan_set, .eth_get, .eth_set, .provision_status, .wifi_ap_show, .wifi_ap_enable, .wifi_ap_disable, .wifi_ap_auto, .factory_reset, .time_status => unreachable,
    };
}

// ---- update install: POST + operation poll ----------------------------------

fn updateInstall(arena: std.mem.Allocator, inv: Invocation) u8 {
    const raw = blk: {
        if (isUrl(inv.target)) {
            // JSON form: cragd hands the URL to RAUC, which streams the
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
                const msg = std.fmt.allocPrint(arena, "cragctl: cannot open bundle {s}\n", .{inv.target}) catch "cragctl: cannot open bundle\n";
                writeAll(posix.STDERR_FILENO, msg);
                return 1;
            },
            else => return transportFail(arena, inv.socket_path, err),
        };
    };
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status != 202) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: install request failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    const op_url = parseOperationRef(arena, resp.body) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: 202 response without an operation URL\n");
        return 1;
    };
    const started = std.fmt.allocPrint(arena, "installing; operation {s}\n", .{op_url}) catch return oom();
    writeAll(posix.STDOUT_FILENO, started);
    return pollOperation(arena, inv.socket_path, op_url, "install");
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
/// `label` names the work in the terminal lines ("install", "scan").
fn pollOperation(arena: std.mem.Allocator, socket_path: []const u8, op_url: []const u8, label: []const u8) u8 {
    const req = std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{op_url}) catch return oom();
    var last_progress: i64 = -1;
    var last_message: []const u8 = "";
    while (true) {
        const raw = exchange(arena, socket_path, req) catch |err|
            return transportFail(arena, socket_path, err);
        const resp = parseResponse(raw) catch {
            writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
            return 1;
        };
        if (resp.status != 200) {
            const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: operation poll failed\n";
            writeAll(posix.STDERR_FILENO, msg);
            return 1;
        }
        const op = parseOperation(arena, resp.body) catch {
            writeAll(posix.STDERR_FILENO, "cragctl: malformed operation document\n");
            return 1;
        };
        if (op.progress != last_progress or !std.mem.eql(u8, op.message, last_message)) {
            const line = std.fmt.allocPrint(arena, "[{d:>3}%] {s}\n", .{ op.progress, op.message }) catch return oom();
            writeAll(posix.STDOUT_FILENO, line);
            last_progress = op.progress;
            last_message = op.message;
        }
        if (std.mem.eql(u8, op.state, "succeeded")) {
            const msg = std.fmt.allocPrint(arena, "{s} operation succeeded\n", .{label}) catch return oom();
            writeAll(posix.STDOUT_FILENO, msg);
            return 0;
        }
        if (std.mem.eql(u8, op.state, "failed")) {
            const msg = std.fmt.allocPrint(arena, "error: {s} operation failed: {s}\n", .{ label, op.err orelse "(no detail)" }) catch "error: operation failed\n";
            writeAll(posix.STDERR_FILENO, msg);
            return 1;
        }
        sync.sleepMs(poll_interval_ms);
    }
}

// ---- network commands (phase 3, docs/06 §5.2) -------------------------------

/// `wifi scan`: POST the scan, poll the returned operation to a terminal
/// state, then fetch and print the results — one command, one exit code.
fn wifiScan(arena: std.mem.Allocator, inv: Invocation) u8 {
    const req = "POST /api/v1/network/wifi/scan HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    const raw = exchange(arena, inv.socket_path, req) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status != 202) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: scan request failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    const op_url = parseOperationRef(arena, resp.body) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: 202 response without an operation URL\n");
        return 1;
    };
    const started = std.fmt.allocPrint(arena, "scanning; operation {s}\n", .{op_url}) catch return oom();
    writeAll(posix.STDOUT_FILENO, started);
    const rc = pollOperation(arena, inv.socket_path, op_url, "scan");
    if (rc != 0) return rc;

    const raw2 = exchange(arena, inv.socket_path, requestFor(.wifi_networks)) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp2 = parseResponse(raw2) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp2.status >= 400) {
        const msg = formatProblem(arena, resp2.status, resp2.body) catch "cragctl: fetching scan results failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    writeAll(posix.STDOUT_FILENO, formatWifiNetworks(arena, resp2.body) catch resp2.body);
    return 0;
}

/// `wifi connect <ssid>`: PUT the profile, then poll GET /network/wifi
/// until the station state reaches "connected" (the authoritative view
/// the network.wifi.state events narrate) or the timeout elapses. State
/// transitions are printed as they are observed.
fn wifiConnect(arena: std.mem.Allocator, inv: Invocation) u8 {
    const psk = if (inv.psk) |p| p else readPskStdin(arena) catch |err| switch (err) {
        error.EmptyPassphrase => {
            writeAll(posix.STDERR_FILENO, "cragctl: empty passphrase on stdin (pass --psk= or pipe the passphrase)\n");
            return 2;
        },
        error.InputOutput => {
            writeAll(posix.STDERR_FILENO, "cragctl: cannot read the passphrase from stdin\n");
            return 1;
        },
        error.OutOfMemory => return oom(),
    };
    const body = std.json.Stringify.valueAlloc(arena, .{ .ssid = inv.target, .psk = psk }, .{}) catch return oom();
    const req = std.fmt.allocPrint(
        arena,
        "PUT /api/v1/network/wifi/connection HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    ) catch return oom();
    const raw = exchange(arena, inv.socket_path, req) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 300) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: connect request failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    const persisted = std.fmt.allocPrint(arena, "profile persisted; waiting for association (timeout {d}s)\n", .{inv.timeout_s}) catch return oom();
    writeAll(posix.STDOUT_FILENO, persisted);

    const state_req = "GET /api/v1/network/wifi HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var waited_ms: u64 = 0;
    var last_state: []const u8 = "";
    while (true) {
        const raw2 = exchange(arena, inv.socket_path, state_req) catch |err|
            return transportFail(arena, inv.socket_path, err);
        const resp2 = parseResponse(raw2) catch {
            writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
            return 1;
        };
        if (resp2.status != 200) {
            const msg = formatProblem(arena, resp2.status, resp2.body) catch "cragctl: wifi state poll failed\n";
            writeAll(posix.STDERR_FILENO, msg);
            return 1;
        }
        const view = parseWifiStateView(arena, resp2.body) catch {
            writeAll(posix.STDERR_FILENO, "cragctl: malformed wifi state document\n");
            return 1;
        };
        if (!std.mem.eql(u8, view.state, last_state)) {
            const line = std.fmt.allocPrint(arena, "state: {s}\n", .{view.state}) catch return oom();
            writeAll(posix.STDOUT_FILENO, line);
            last_state = view.state;
        }
        if (std.mem.eql(u8, view.state, "connected")) {
            const done = std.fmt.allocPrint(arena, "connected to {s}\n", .{view.connected_ssid orelse inv.target}) catch return oom();
            writeAll(posix.STDOUT_FILENO, done);
            return 0;
        }
        if (waited_ms >= @as(u64, inv.timeout_s) * 1000) {
            const msg = std.fmt.allocPrint(arena, "error: not connected after {d}s (last state: {s})\n", .{ inv.timeout_s, last_state }) catch "error: connect timed out\n";
            writeAll(posix.STDERR_FILENO, msg);
            return 1;
        }
        sync.sleepMs(poll_interval_ms);
        waited_ms += poll_interval_ms;
    }
}

/// `wan set <csv>`: PUT the parsed order, print the applied policy.
fn wanSet(arena: std.mem.Allocator, inv: Invocation) u8 {
    const body = buildWanBody(arena, inv.target) catch |err| switch (err) {
        error.BadOrder => {
            writeAll(posix.STDERR_FILENO, "cragctl: bad wan order (comma-separated interface classes, e.g. ethernet,wifi)\n");
            return 2;
        },
        error.OutOfMemory => return oom(),
    };
    const req = std.fmt.allocPrint(
        arena,
        "PUT /api/v1/network/wan HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    ) catch return oom();
    const raw = exchange(arena, inv.socket_path, req) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: wan set failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    writeAll(posix.STDOUT_FILENO, formatWanPolicy(arena, resp.body) catch resp.body);
    return 0;
}

/// `ethernet get|set <iface>`: GET, or PUT built from --dhcp/--static=.
fn ethernetCommand(arena: std.mem.Allocator, inv: Invocation) u8 {
    const path = std.fmt.allocPrint(arena, "/api/v1/network/ethernet/{s}", .{inv.target}) catch return oom();
    const req = blk: {
        if (inv.action == .eth_get)
            break :blk std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{path}) catch return oom();
        // parseCommand already validated the spec/mode flags.
        const body = buildEthernetBody(arena, inv.static_spec, inv.dhcp) catch |err| switch (err) {
            error.BadSpec => {
                writeAll(posix.STDERR_FILENO, "cragctl: bad --static spec (ADDR/PREFIX[,GW])\n");
                return 2;
            },
            error.OutOfMemory => return oom(),
        };
        break :blk std.fmt.allocPrint(
            arena,
            "PUT {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ path, body.len, body },
        ) catch return oom();
    };
    const raw = exchange(arena, inv.socket_path, req) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: ethernet request failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    writeAll(posix.STDOUT_FILENO, formatEthernetConfig(arena, resp.body) catch resp.body);
    return 0;
}

// ---- provisioning commands (phase 4, docs/07 §4-§6) -------------------------

/// `provision status`: GET /system for the state-machine summary, then
/// GET /network and GET /network/wifi for the wired/wifi observations the
/// machine consumes (docs/07 §4). The observation endpoints degrade to
/// "unavailable" lines instead of failing the command — the state line is
/// the contract, the observations are context.
fn provisionStatus(arena: std.mem.Allocator, inv: Invocation) u8 {
    const raw = exchange(arena, inv.socket_path, requestFor(.show_system)) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: provision status failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    const network_body: ?[]const u8 = blk: {
        const r = exchange(arena, inv.socket_path, requestFor(.network)) catch break :blk null;
        const p = parseResponse(r) catch break :blk null;
        break :blk if (p.status == 200) p.body else null;
    };
    const wifi_body: ?[]const u8 = blk: {
        const req = "GET /api/v1/network/wifi HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        const r = exchange(arena, inv.socket_path, req) catch break :blk null;
        const p = parseResponse(r) catch break :blk null;
        break :blk if (p.status == 200) p.body else null;
    };
    const out = formatProvisionStatus(arena, resp.body, network_body, wifi_body) catch resp.body;
    writeAll(posix.STDOUT_FILENO, out);
    return 0;
}

/// `wifi ap show`: GET /network/wifi/ap for the live state, plus the
/// DERIVED per-device PSK computed locally from /etc/machine-id — this
/// command is the socket-surface-only label story (docs/07 §4): the PSK
/// is never served by any HTTP endpoint, so reading it requires being on
/// the device with the group-gated socket AND readable machine-id.
fn wifiApShow(arena: std.mem.Allocator, inv: Invocation) u8 {
    const req = "GET /api/v1/network/wifi/ap HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const raw = exchange(arena, inv.socket_path, req) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: wifi ap show failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    var psk_buf: [16]u8 = undefined;
    var id_buf: [128]u8 = undefined;
    const derived_psk: ?[]const u8 = blk: {
        const text = fsutil.readFileBounded(machine_id_path, &id_buf) catch break :blk null;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) break :blk null;
        break :blk wifi.deriveApPsk(&psk_buf, trimmed);
    };
    const out = formatWifiApState(arena, resp.body, derived_psk) catch resp.body;
    writeAll(posix.STDOUT_FILENO, out);
    return 0;
}

const machine_id_path = "/etc/machine-id";

/// PUT /api/v1/network/wifi/ap body per mode: the tri-state override
/// (docs/06 §5.2 WifiApConfig — true forces up, false forces down, null
/// returns control to the provisioning state machine).
pub fn apBodyFor(action: Action) []const u8 {
    return switch (action) {
        .wifi_ap_enable => "{\"enabled\":true}",
        .wifi_ap_disable => "{\"enabled\":false}",
        .wifi_ap_auto => "{\"enabled\":null}",
        else => unreachable,
    };
}

/// `wifi ap enable|disable|auto`: PUT the override, print the applied
/// state (no PSK line — only `show` derives it).
fn wifiApSet(arena: std.mem.Allocator, inv: Invocation) u8 {
    const body = apBodyFor(inv.action);
    const req = std.fmt.allocPrint(
        arena,
        "PUT /api/v1/network/wifi/ap HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    ) catch return oom();
    const raw = exchange(arena, inv.socket_path, req) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: wifi ap request failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    writeAll(posix.STDOUT_FILENO, formatWifiApState(arena, resp.body, null) catch resp.body);
    return 0;
}

/// `factory-reset`: confirm-with-serial (docs/06 §5.1). Interactive form
/// fetches this device's machine-id, shows it, and requires it typed
/// back; --yes-really-wipe takes it as the positional argument instead.
/// Either way the API re-verifies — the CLI never sends a confirm it
/// invented.
fn factoryReset(arena: std.mem.Allocator, inv: Invocation) u8 {
    const confirm: []const u8 = blk: {
        if (inv.yes_really_wipe) break :blk inv.target;
        const raw = exchange(arena, inv.socket_path, requestFor(.show_system)) catch |err|
            return transportFail(arena, inv.socket_path, err);
        const resp = parseResponse(raw) catch {
            writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
            return 1;
        };
        if (resp.status >= 400) {
            const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: cannot fetch the machine-id\n";
            writeAll(posix.STDERR_FILENO, msg);
            return 1;
        }
        const mid = parseMachineId(arena, resp.body) catch {
            writeAll(posix.STDERR_FILENO, "cragctl: system document without a machine_id\n");
            return 1;
        };
        const prompt = std.fmt.allocPrint(arena,
            \\factory reset WIPES all device data (/data: config, keys, logs,
            \\wifi credentials, API token) and reboots. Firmware slots survive.
            \\device machine-id: {s}
            \\type the machine-id to confirm:
        ++ " ", .{mid}) catch return oom();
        writeAll(posix.STDOUT_FILENO, prompt);
        const line = readLineStdin(arena) catch |err| switch (err) {
            error.EmptyLine => {
                writeAll(posix.STDERR_FILENO, "cragctl: aborted (nothing entered)\n");
                return 2;
            },
            error.InputOutput => {
                writeAll(posix.STDERR_FILENO, "cragctl: cannot read the confirmation from stdin\n");
                return 1;
            },
            error.OutOfMemory => return oom(),
        };
        break :blk line;
    };
    const body = std.json.Stringify.valueAlloc(arena, .{ .confirm = confirm }, .{}) catch return oom();
    const req = std.fmt.allocPrint(
        arena,
        "POST /api/v1/system/factory-reset HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    ) catch return oom();
    const raw = exchange(arena, inv.socket_path, req) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: factory reset refused\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    writeAll(posix.STDOUT_FILENO, "factory reset accepted; the device reboots and wipes /data now\n");
    return 0;
}

/// `time`: the daemon's synced view (GET /system time_synced — adjtimex
/// STA_UNSYNC via cragd, docs/07 §6) plus the LOCAL floor context read
/// the same way cragd reads it (build-epoch + last-known-time files).
fn timeStatus(arena: std.mem.Allocator, inv: Invocation) u8 {
    const raw = exchange(arena, inv.socket_path, requestFor(.show_system)) catch |err|
        return transportFail(arena, inv.socket_path, err);
    const resp = parseResponse(raw) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
        return 1;
    };
    if (resp.status >= 400) {
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: time status failed\n";
        writeAll(posix.STDERR_FILENO, msg);
        return 1;
    }
    const floor = timekeep.floorEpoch(timekeep.build_epoch_path, timekeep.last_known_path);
    const now = timekeep.nowRealtime();
    const out = formatTimeStatus(arena, resp.body, floor, now) catch resp.body;
    writeAll(posix.STDOUT_FILENO, out);
    return 0;
}

/// Read the WPA passphrase from stdin (first line, or everything up to
/// EOF): `wifi connect` without --psk= keeps the secret out of argv and
/// thus out of /proc/*/cmdline.
fn readPskStdin(arena: std.mem.Allocator) error{ EmptyPassphrase, InputOutput, OutOfMemory }![]const u8 {
    return readLineStdin(arena) catch |err| switch (err) {
        error.EmptyLine => error.EmptyPassphrase,
        else => |e| e,
    };
}

/// First stdin line (or everything up to EOF), CR/LF-trimmed; also the
/// factory-reset confirm reader.
fn readLineStdin(arena: std.mem.Allocator) error{ EmptyLine, InputOutput, OutOfMemory }![]const u8 {
    var buf: [256]u8 = undefined;
    var data: std.ArrayList(u8) = .empty;
    while (data.items.len < 256) {
        const n = posix.read(posix.STDIN_FILENO, &buf) catch return error.InputOutput;
        if (n == 0) break;
        try data.appendSlice(arena, buf[0..n]);
        if (std.mem.indexOfScalar(u8, data.items, '\n') != null) break;
    }
    var s: []const u8 = data.items;
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| s = s[0..i];
    s = std.mem.trimEnd(u8, s, "\r");
    if (s.len == 0) return error.EmptyLine;
    return s;
}

// ---- events: SSE reader -----------------------------------------------------

// Design choice (documented): `cragctl events` always requests a FULL
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
            writeAll(posix.STDERR_FILENO, "cragctl: read error on event stream\n");
            return 1;
        };
        if (n == 0) {
            writeAll(posix.STDERR_FILENO, "cragctl: connection closed before a response arrived\n");
            return 1;
        }
        head.appendSlice(arena, buf[0..n]) catch return oom();
        if (std.mem.indexOf(u8, head.items, "\r\n\r\n")) |i| break i + 4;
        if (head.items.len > max_response_len) {
            writeAll(posix.STDERR_FILENO, "cragctl: oversized response head\n");
            return 1;
        }
    };
    const status = statusOf(head.items) catch {
        writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
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
            writeAll(posix.STDERR_FILENO, "cragctl: malformed HTTP response from cragd\n");
            return 1;
        };
        const msg = formatProblem(arena, resp.status, resp.body) catch "cragctl: event stream refused\n";
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
            writeAll(posix.STDERR_FILENO, "cragctl: poll error on event stream\n");
            return 1;
        };
        if (ready == 0) return 0; // drain mode: quiet period reached
        const n = posix.read(fd, &buf) catch {
            writeAll(posix.STDERR_FILENO, "cragctl: read error on event stream\n");
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

/// Parse a complete HTTP/1.1 response. cragd always closes after one
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
            try appendRow(allocator, &out, &headers, &widths);
            for (rows.items) |row| try appendRow(allocator, &out, &row, &widths);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Append one two-space-separated table row; the last column is never
/// padded (keeps lines free of trailing spaces).
fn appendRow(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cells: []const []const u8, widths: []const usize) !void {
    for (cells, 0..) |cell, i| {
        try out.appendSlice(allocator, cell);
        if (i + 1 < cells.len) {
            var pad = widths[i] - cell.len + 2;
            while (pad > 0) : (pad -= 1) try out.append(allocator, ' ');
        }
    }
    try out.append(allocator, '\n');
}

// ---- network parsing and rendering (pure, tested) ---------------------------

/// The GET /api/v1/network/wifi fields the connect poll loop consumes
/// (spec WifiState). Strings are duped into `allocator` — pass an arena.
pub const WifiStateView = struct {
    state: []const u8,
    connected_ssid: ?[]const u8,
};

pub fn parseWifiStateView(allocator: std.mem.Allocator, body: []const u8) !WifiStateView {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const obj = parsed.value.object;
    const state_v = obj.get("state") orelse return error.BadResponse;
    if (state_v != .string) return error.BadResponse;
    const ssid: ?[]const u8 = if (obj.get("connected_ssid")) |s| switch (s) {
        .string => |x| try allocator.dupe(u8, x),
        else => null,
    } else null;
    return .{ .state = try allocator.dupe(u8, state_v.string), .connected_ssid = ssid };
}

/// --static=ADDR/PREFIX[,GW] parsed; slices alias the argument.
pub const StaticSpec = struct {
    address: []const u8,
    prefix: u8,
    gateway: ?[]const u8,
};

pub fn parseStaticSpec(spec: []const u8) error{BadSpec}!StaticSpec {
    var parts = std.mem.splitScalar(u8, spec, ',');
    const addr_part = parts.next() orelse return error.BadSpec;
    const gateway = parts.next();
    if (parts.next() != null) return error.BadSpec;
    const slash = std.mem.indexOfScalar(u8, addr_part, '/') orelse return error.BadSpec;
    const address = addr_part[0..slash];
    const prefix = std.fmt.parseInt(u8, addr_part[slash + 1 ..], 10) catch return error.BadSpec;
    if (address.len == 0 or prefix > 32) return error.BadSpec;
    if (gateway) |g| {
        if (g.len == 0) return error.BadSpec;
    }
    return .{ .address = address, .prefix = prefix, .gateway = gateway };
}

/// PUT /api/v1/network/wan body from the CLI's comma-separated order.
pub fn buildWanBody(allocator: std.mem.Allocator, csv: []const u8) error{ BadOrder, OutOfMemory }![]u8 {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(allocator);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) return error.BadOrder;
        try items.append(allocator, item);
    }
    if (items.items.len == 0) return error.BadOrder;
    return std.json.Stringify.valueAlloc(allocator, .{ .order = items.items }, .{});
}

/// PUT /api/v1/network/ethernet/{iface} body (spec EthernetConfig; full
/// replace, so omitted members reset — the CLI sends only ipv4).
pub fn buildEthernetBody(allocator: std.mem.Allocator, static_spec: ?[]const u8, dhcp: bool) error{ BadSpec, OutOfMemory }![]u8 {
    if (dhcp)
        return std.json.Stringify.valueAlloc(allocator, .{ .ipv4 = .{ .mode = "dhcp" } }, .{});
    const spec = try parseStaticSpec(static_spec orelse return error.BadSpec);
    return std.json.Stringify.valueAlloc(allocator, .{ .ipv4 = .{
        .mode = "static",
        .address = spec.address,
        .prefix = spec.prefix,
        .gateway = spec.gateway,
    } }, .{});
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn yesNo(value: ?std.json.Value) []const u8 {
    const v = value orelse return "-";
    return switch (v) {
        .bool => |b| if (b) "yes" else "no",
        else => "-",
    };
}

/// Pretty-print GET /api/v1/network (spec NetworkStatus): an aligned
/// interface table plus the WAN order line. Pass an arena — intermediate
/// cell strings are not individually freed.
pub fn formatNetworkOverview(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const obj = parsed.value.object;
    const ifs_v = obj.get("interfaces") orelse return error.BadResponse;
    if (ifs_v != .array) return error.BadResponse;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const headers = [_][]const u8{ "IFACE", "TYPE", "UP", "CARRIER", "ADDRESSES" };
    var rows: std.ArrayList([5][]const u8) = .empty;
    defer rows.deinit(allocator);
    for (ifs_v.array.items) |iface_v| {
        if (iface_v != .object) continue;
        const io = iface_v.object;
        var addrs: []const u8 = "-";
        if (io.get("addresses")) |addrs_v| {
            if (addrs_v == .array and addrs_v.array.items.len > 0) {
                var joined: std.ArrayList(u8) = .empty;
                for (addrs_v.array.items) |a| {
                    if (a != .string) continue;
                    if (joined.items.len > 0) try joined.append(allocator, ',');
                    try joined.appendSlice(allocator, a.string);
                }
                if (joined.items.len > 0) addrs = joined.items;
            }
        }
        try rows.append(allocator, .{
            jsonString(io.get("name")) orelse "-",
            jsonString(io.get("type")) orelse "-",
            yesNo(io.get("up")),
            yesNo(io.get("carrier")),
            addrs,
        });
    }

    var widths: [5]usize = undefined;
    for (headers, 0..) |h, i| widths[i] = h.len;
    for (rows.items) |row| {
        for (row, 0..) |cell, i| widths[i] = @max(widths[i], cell.len);
    }
    try appendRow(allocator, &out, &headers, &widths);
    for (rows.items) |row| try appendRow(allocator, &out, &row, &widths);

    if (obj.get("wan")) |wan_v| {
        if (wan_v == .object) {
            if (wan_v.object.get("order")) |order_v| {
                if (order_v == .array) {
                    try out.appendSlice(allocator, "\nwan order: ");
                    var first = true;
                    for (order_v.array.items) |o| {
                        if (o != .string) continue;
                        if (!first) try out.appendSlice(allocator, ", ");
                        try out.appendSlice(allocator, o.string);
                        first = false;
                    }
                    try out.append(allocator, '\n');
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Pretty-print GET /api/v1/network/wifi/networks (spec WifiNetwork[]).
/// Pass an arena — intermediate cell strings are not individually freed.
pub fn formatWifiNetworks(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.BadResponse;
    const nets = parsed.value.array.items;
    if (nets.len == 0)
        return allocator.dupe(u8, "no networks seen; run 'cragctl wifi scan'\n");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const headers = [_][]const u8{ "SSID", "SIGNAL", "SECURITY", "KNOWN", "CONNECTED" };
    var rows: std.ArrayList([5][]const u8) = .empty;
    defer rows.deinit(allocator);
    for (nets) |net_v| {
        if (net_v != .object) continue;
        const no = net_v.object;
        const signal: []const u8 = if (no.get("signal_dbm")) |s| switch (s) {
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            else => "-",
        } else "-";
        try rows.append(allocator, .{
            jsonString(no.get("ssid")) orelse "-",
            signal,
            jsonString(no.get("security")) orelse "-",
            if (no.get("known")) |k| (if (k == .bool and k.bool) "yes" else "-") else "-",
            if (no.get("connected")) |c| (if (c == .bool and c.bool) "yes" else "-") else "-",
        });
    }
    var widths: [5]usize = undefined;
    for (headers, 0..) |h, i| widths[i] = h.len;
    for (rows.items) |row| {
        for (row, 0..) |cell, i| widths[i] = @max(widths[i], cell.len);
    }
    try appendRow(allocator, &out, &headers, &widths);
    for (rows.items) |row| try appendRow(allocator, &out, &row, &widths);
    return out.toOwnedSlice(allocator);
}

/// Render GET/PUT /api/v1/network/wan responses: "order: a, b".
pub fn formatWanPolicy(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const order_v = parsed.value.object.get("order") orelse return error.BadResponse;
    if (order_v != .array) return error.BadResponse;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "order: ");
    var first = true;
    for (order_v.array.items) |o| {
        if (o != .string) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, o.string);
        first = false;
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// Pretty-print an EthernetConfig document as aligned key/value lines.
/// Pass an arena — intermediate strings are not individually freed.
pub fn formatEthernetConfig(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const obj = parsed.value.object;

    var mode: []const u8 = "-";
    var address: []const u8 = "-";
    var prefix: []const u8 = "-";
    var gateway: []const u8 = "-";
    if (obj.get("ipv4")) |ipv4_v| {
        if (ipv4_v == .object) {
            const v4 = ipv4_v.object;
            mode = jsonString(v4.get("mode")) orelse "-";
            address = jsonString(v4.get("address")) orelse "-";
            gateway = jsonString(v4.get("gateway")) orelse "-";
            if (v4.get("prefix")) |p| {
                if (p == .integer) prefix = try std.fmt.allocPrint(allocator, "{d}", .{p.integer});
            }
        }
    }
    var dns: []const u8 = "-";
    if (obj.get("dns")) |dns_v| {
        if (dns_v == .array and dns_v.array.items.len > 0) {
            var joined: std.ArrayList(u8) = .empty;
            for (dns_v.array.items) |d| {
                if (d != .string) continue;
                if (joined.items.len > 0) try joined.append(allocator, ',');
                try joined.appendSlice(allocator, d.string);
            }
            if (joined.items.len > 0) dns = joined.items;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const pairs = [_][2][]const u8{
        .{ "mode", mode },
        .{ "address", address },
        .{ "prefix", prefix },
        .{ "gateway", gateway },
        .{ "dns", dns },
    };
    for (pairs) |pair| {
        const line = try std.fmt.allocPrint(allocator, "{s:<9} {s}\n", .{ pair[0], pair[1] });
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

// ---- provisioning parsing and rendering (pure, tested) ----------------------

/// machine_id out of a GET /system document (spec SystemInfo; absent on
/// the redacted AP variant — but this CLI only speaks the unix socket).
/// Duped into `allocator` — pass an arena.
pub fn parseMachineId(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const mid = parsed.value.object.get("machine_id") orelse return error.BadResponse;
    if (mid != .string or mid.string.len == 0) return error.BadResponse;
    return try allocator.dupe(u8, mid.string);
}

/// `provision status` rendering: the state line from GET /system, one
/// wired line per ethernet interface from GET /network, the wifi summary
/// from GET /network/wifi. A null observation body renders "unavailable"
/// (endpoint 501/absent) — the state line alone is still truthful.
/// Pass an arena — intermediate strings are not individually freed.
pub fn formatProvisionStatus(allocator: std.mem.Allocator, system_body: []const u8, network_body: ?[]const u8, wifi_body: ?[]const u8) ![]u8 {
    var sys_parsed = try std.json.parseFromSlice(std.json.Value, allocator, system_body, .{});
    defer sys_parsed.deinit();
    if (sys_parsed.value != .object) return error.BadResponse;
    const state = jsonString(sys_parsed.value.object.get("provisioning")) orelse return error.BadResponse;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "state    {s}\n", .{state}));

    if (network_body) |nb| blk: {
        var net_parsed = std.json.parseFromSlice(std.json.Value, allocator, nb, .{}) catch {
            try out.appendSlice(allocator, "wired    unavailable\n");
            break :blk;
        };
        defer net_parsed.deinit();
        const ifs_v = if (net_parsed.value == .object) net_parsed.value.object.get("interfaces") else null;
        if (ifs_v == null or ifs_v.? != .array) {
            try out.appendSlice(allocator, "wired    unavailable\n");
            break :blk;
        }
        var any_eth = false;
        for (ifs_v.?.array.items) |iface_v| {
            if (iface_v != .object) continue;
            const io = iface_v.object;
            const t = jsonString(io.get("type")) orelse continue;
            if (!std.mem.eql(u8, t, "ethernet")) continue;
            any_eth = true;
            const name = jsonString(io.get("name")) orelse "-";
            const carrier = yesNo(io.get("carrier"));
            var addr: []const u8 = "no address";
            if (io.get("addresses")) |av| {
                if (av == .array and av.array.items.len > 0 and av.array.items[0] == .string)
                    addr = av.array.items[0].string;
            }
            try out.appendSlice(allocator, try std.fmt.allocPrint(
                allocator,
                "wired    {s}: carrier {s}, {s}\n",
                .{ name, carrier, addr },
            ));
        }
        if (!any_eth) try out.appendSlice(allocator, "wired    none\n");
    } else {
        try out.appendSlice(allocator, "wired    unavailable\n");
    }

    if (wifi_body) |wb| blk: {
        var wifi_parsed = std.json.parseFromSlice(std.json.Value, allocator, wb, .{}) catch {
            try out.appendSlice(allocator, "wifi     unavailable\n");
            break :blk;
        };
        defer wifi_parsed.deinit();
        if (wifi_parsed.value != .object) {
            try out.appendSlice(allocator, "wifi     unavailable\n");
            break :blk;
        }
        const wo = wifi_parsed.value.object;
        const wstate = jsonString(wo.get("state")) orelse "unavailable";
        const mode = jsonString(wo.get("mode")) orelse "-";
        if (std.mem.eql(u8, wstate, "connected")) {
            const ssid = jsonString(wo.get("connected_ssid")) orelse "-";
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "wifi     connected to {s}\n", .{ssid}));
        } else if (std.mem.eql(u8, mode, "ap")) {
            try out.appendSlice(allocator, "wifi     ap (provisioning portal up)\n");
        } else {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "wifi     {s}\n", .{wstate}));
        }
    } else {
        try out.appendSlice(allocator, "wifi     unavailable\n");
    }

    return out.toOwnedSlice(allocator);
}

/// WifiApState rendering (spec: enabled/ssid/subnet). `derived_psk` is
/// the locally derived label passphrase — appended only by `wifi ap
/// show`, the socket-only PSK surface; null (enable/disable/auto, or an
/// unreadable machine-id) renders no psk line at all.
pub fn formatWifiApState(allocator: std.mem.Allocator, body: []const u8, derived_psk: ?[]const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const obj = parsed.value.object;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "enabled  {s}\n", .{yesNo(obj.get("enabled"))}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "ssid     {s}\n", .{jsonString(obj.get("ssid")) orelse "-"}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "subnet   {s}\n", .{jsonString(obj.get("subnet")) orelse "-"}));
    if (derived_psk) |psk| {
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "psk      {s}\n", .{psk}));
    }
    return out.toOwnedSlice(allocator);
}

/// `time` rendering: the daemon's synced flag plus the local floor
/// context. floor_ok makes the docs/07 §6 gate condition (synced OR past
/// the floor) readable at a glance.
pub fn formatTimeStatus(allocator: std.mem.Allocator, system_body: []const u8, floor: i64, now: i64) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, system_body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const synced = yesNo(parsed.value.object.get("time_synced"));
    return std.fmt.allocPrint(
        allocator,
        "synced   {s}\nfloor    {d}\nnow      {d}\nfloor_ok {s}\n",
        .{ synced, floor, now, if (now >= floor) "yes" else "no" },
    );
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
// "cannot reach cragd" message; the rest collapse to Unexpected.
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
    const msg = std.fmt.allocPrint(arena, "cragctl: cannot reach cragd at {s} ({t}) — is cragd running?\n", .{ socket_path, err }) catch "cragctl: cannot reach cragd\n";
    writeAll(posix.STDERR_FILENO, msg);
    return 1;
}

fn oom() u8 {
    writeAll(posix.STDERR_FILENO, "cragctl: out of memory\n");
    return 1;
}

// Raw write(2): stable across the std.Io churn and cragctl output is
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
    const forced = parseCommand(&.{ "update", "install", "--force", "https://example.com/crag.raucb" });
    try std.testing.expectEqual(Action.update_install, forced.invoke.action);
    try std.testing.expectEqualStrings("https://example.com/crag.raucb", forced.invoke.target);
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

    const with_detail = try formatProblem(a, 501, "{\"type\":\"urn:crag:problem:not-implemented\",\"title\":\"Not Implemented\",\"status\":501,\"detail\":\"dinit client not wired\"}");
    defer a.free(with_detail);
    try std.testing.expectEqualStrings("error: Not Implemented: dinit client not wired\n", with_detail);

    const no_detail = try formatProblem(a, 404, "{\"type\":\"urn:crag:problem:not-found\",\"title\":\"Not Found\",\"status\":404}");
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
        \\{"boot_slot":"A","primary":"rootfs.1","operation":"idle","last_error":"","compatible":"crag-virt",
        \\ "slots":[
        \\  {"name":"rootfs.0","state":"booted","bundle_version":"0.0.0-dev","boot_status":"good","boot_attempts_left":3,"device":"/dev/vda5"},
        \\  {"name":"rootfs.1","state":"inactive","bundle_version":"","boot_status":"good","boot_attempts_left":null,"device":"/dev/vda6"}]}
    ;
    const out = try formatUpdateStatus(arena, body);
    const expected =
        "boot_slot    A\n" ++
        "primary      rootfs.1\n" ++
        "operation    idle\n" ++
        "compatible   crag-virt\n" ++
        "last_error   -\n" ++
        "\n" ++
        "SLOT      STATE     VERSION    BOOT  ATTEMPTS  DEVICE\n" ++
        "rootfs.0  booted    0.0.0-dev  good  3         /dev/vda5\n" ++
        "rootfs.1  inactive  -          good  -         /dev/vda6\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "parseCommand: network command group" {
    const net = parseCommand(&.{"network"});
    try std.testing.expectEqual(Action.network, net.invoke.action);

    const scan = parseCommand(&.{ "wifi", "scan" });
    try std.testing.expectEqual(Action.wifi_scan, scan.invoke.action);

    const nets = parseCommand(&.{ "wifi", "networks" });
    try std.testing.expectEqual(Action.wifi_networks, nets.invoke.action);

    const forget = parseCommand(&.{ "wifi", "forget" });
    try std.testing.expectEqual(Action.wifi_forget, forget.invoke.action);

    const connect = parseCommand(&.{ "wifi", "connect", "cafe-24" });
    try std.testing.expectEqual(Action.wifi_connect, connect.invoke.action);
    try std.testing.expectEqualStrings("cafe-24", connect.invoke.target);
    try std.testing.expectEqual(@as(?[]const u8, null), connect.invoke.psk);
    try std.testing.expectEqual(default_connect_timeout_s, connect.invoke.timeout_s);

    const with_psk = parseCommand(&.{ "wifi", "connect", "cafe-24", "--psk=hunter22", "--timeout=10" });
    try std.testing.expectEqualStrings("hunter22", with_psk.invoke.psk.?);
    try std.testing.expectEqual(@as(u32, 10), with_psk.invoke.timeout_s);

    const wan_get = parseCommand(&.{ "wan", "get" });
    try std.testing.expectEqual(Action.wan_get, wan_get.invoke.action);

    const wan_set = parseCommand(&.{ "wan", "set", "wifi,ethernet" });
    try std.testing.expectEqual(Action.wan_set, wan_set.invoke.action);
    try std.testing.expectEqualStrings("wifi,ethernet", wan_set.invoke.target);

    const eget = parseCommand(&.{ "ethernet", "get", "eth0" });
    try std.testing.expectEqual(Action.eth_get, eget.invoke.action);
    try std.testing.expectEqualStrings("eth0", eget.invoke.target);

    const eset_dhcp = parseCommand(&.{ "ethernet", "set", "eth0", "--dhcp" });
    try std.testing.expectEqual(Action.eth_set, eset_dhcp.invoke.action);
    try std.testing.expect(eset_dhcp.invoke.dhcp);

    const eset_static = parseCommand(&.{ "ethernet", "set", "eth0", "--static=192.168.7.2/24,192.168.7.1" });
    try std.testing.expectEqual(Action.eth_set, eset_static.invoke.action);
    try std.testing.expectEqualStrings("192.168.7.2/24,192.168.7.1", eset_static.invoke.static_spec.?);
}

test "parseCommand: network group usage errors and flag applicability" {
    // Missing positional arguments.
    try std.testing.expect(parseCommand(&.{ "wifi", "connect" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "wan", "set" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "ethernet", "get" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "ethernet", "set", "eth0" }) == .usage_error); // no mode picked
    try std.testing.expect(parseCommand(&.{"wifi"}) == .usage_error);
    try std.testing.expect(parseCommand(&.{"wan"}) == .usage_error);

    // Mode flags: exactly one of --dhcp / --static=, and only on set.
    try std.testing.expect(parseCommand(&.{ "ethernet", "set", "eth0", "--dhcp", "--static=10.0.0.2/24" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "ethernet", "get", "eth0", "--dhcp" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "ethernet", "set", "eth0", "--static=notanaddress" }) == .usage_error);

    // Misplaced flags are usage errors, not silently ignored intent.
    try std.testing.expect(parseCommand(&.{ "network", "--psk=x" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "wifi", "scan", "--timeout=5" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "wifi", "connect", "x", "--follow" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "wifi", "connect", "x", "--timeout=0" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "wifi", "connect", "x", "--psk=" }) == .usage_error);

    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{"network"}));
    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{ "wifi", "connect", "x", "--psk=secret12" }));
    try std.testing.expectEqual(@as(u8, 2), evaluate(&.{ "wifi", "connect" }));
}

test "parseStaticSpec accepts ADDR/PREFIX[,GW] and rejects malformed specs" {
    const full = try parseStaticSpec("192.168.7.2/24,192.168.7.1");
    try std.testing.expectEqualStrings("192.168.7.2", full.address);
    try std.testing.expectEqual(@as(u8, 24), full.prefix);
    try std.testing.expectEqualStrings("192.168.7.1", full.gateway.?);

    const no_gw = try parseStaticSpec("10.0.0.2/16");
    try std.testing.expectEqualStrings("10.0.0.2", no_gw.address);
    try std.testing.expectEqual(@as(u8, 16), no_gw.prefix);
    try std.testing.expectEqual(@as(?[]const u8, null), no_gw.gateway);

    try std.testing.expectError(error.BadSpec, parseStaticSpec("10.0.0.2"));
    try std.testing.expectError(error.BadSpec, parseStaticSpec("10.0.0.2/33"));
    try std.testing.expectError(error.BadSpec, parseStaticSpec("/24"));
    try std.testing.expectError(error.BadSpec, parseStaticSpec("10.0.0.2/24,"));
    try std.testing.expectError(error.BadSpec, parseStaticSpec("10.0.0.2/24,gw,extra"));
}

test "buildWanBody and buildEthernetBody produce spec-shaped JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wan = try buildWanBody(arena, "wifi, ethernet");
    try std.testing.expectEqualStrings("{\"order\":[\"wifi\",\"ethernet\"]}", wan);
    try std.testing.expectError(error.BadOrder, buildWanBody(arena, ""));
    try std.testing.expectError(error.BadOrder, buildWanBody(arena, "wifi,,ethernet"));

    const dhcp = try buildEthernetBody(arena, null, true);
    try std.testing.expectEqualStrings("{\"ipv4\":{\"mode\":\"dhcp\"}}", dhcp);

    const with_gw = try buildEthernetBody(arena, "192.168.7.2/24,192.168.7.1", false);
    try std.testing.expectEqualStrings(
        "{\"ipv4\":{\"mode\":\"static\",\"address\":\"192.168.7.2\",\"prefix\":24,\"gateway\":\"192.168.7.1\"}}",
        with_gw,
    );

    const no_gw = try buildEthernetBody(arena, "10.0.0.2/16", false);
    try std.testing.expectEqualStrings(
        "{\"ipv4\":{\"mode\":\"static\",\"address\":\"10.0.0.2\",\"prefix\":16,\"gateway\":null}}",
        no_gw,
    );

    try std.testing.expectError(error.BadSpec, buildEthernetBody(arena, null, false));
}

test "formatNetworkOverview renders the interface table and wan order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"interfaces":[
        \\ {"name":"eth0","type":"ethernet","mac":"52:54:00:12:34:56","up":true,"carrier":true,"addresses":["10.0.2.15/24"],"rssi_dbm":null,"wan_role":"primary"},
        \\ {"name":"wlan0","type":"wifi","mac":null,"up":true,"carrier":false,"addresses":[],"rssi_dbm":null,"wan_role":"backup"}],
        \\ "wan":{"order":["ethernet","wifi"]}}
    ;
    const out = try formatNetworkOverview(arena, body);
    const expected =
        "IFACE  TYPE      UP   CARRIER  ADDRESSES\n" ++
        "eth0   ethernet  yes  yes      10.0.2.15/24\n" ++
        "wlan0  wifi      yes  no       -\n" ++
        "\nwan order: ethernet, wifi\n";
    try std.testing.expectEqualStrings(expected, out);

    try std.testing.expectError(error.BadResponse, formatNetworkOverview(arena, "{}"));
    try std.testing.expectError(error.BadResponse, formatNetworkOverview(arena, "[]"));
}

test "formatWifiNetworks renders the scan table and the empty case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\[{"ssid":"crag-test","signal_dbm":-42,"security":"psk","known":true,"connected":false},
        \\ {"ssid":"cafe","signal_dbm":-70,"security":"open","known":false,"connected":false}]
    ;
    const out = try formatWifiNetworks(arena, body);
    const expected =
        "SSID       SIGNAL  SECURITY  KNOWN  CONNECTED\n" ++
        "crag-test  -42     psk       yes    -\n" ++
        "cafe       -70     open      -      -\n";
    try std.testing.expectEqualStrings(expected, out);

    const empty = try formatWifiNetworks(arena, "[]");
    try std.testing.expectEqualStrings("no networks seen; run 'cragctl wifi scan'\n", empty);
    try std.testing.expectError(error.BadResponse, formatWifiNetworks(arena, "{}"));
}

test "formatWanPolicy and formatEthernetConfig" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wan = try formatWanPolicy(arena, "{\"order\":[\"ethernet\",\"wifi\"]}");
    try std.testing.expectEqualStrings("order: ethernet, wifi\n", wan);
    try std.testing.expectError(error.BadResponse, formatWanPolicy(arena, "{}"));

    const static_cfg = try formatEthernetConfig(arena,
        \\{"ipv4":{"mode":"static","address":"192.168.7.2","prefix":24,"gateway":null},"dns":["1.1.1.1","9.9.9.9"]}
    );
    const expected =
        "mode      static\n" ++
        "address   192.168.7.2\n" ++
        "prefix    24\n" ++
        "gateway   -\n" ++
        "dns       1.1.1.1,9.9.9.9\n";
    try std.testing.expectEqualStrings(expected, static_cfg);

    const dhcp_cfg = try formatEthernetConfig(arena, "{\"ipv4\":{\"mode\":\"dhcp\",\"address\":null,\"prefix\":null,\"gateway\":null},\"dns\":[]}");
    const expected_dhcp =
        "mode      dhcp\n" ++
        "address   -\n" ++
        "prefix    -\n" ++
        "gateway   -\n" ++
        "dns       -\n";
    try std.testing.expectEqualStrings(expected_dhcp, dhcp_cfg);
}

test "parseWifiStateView extracts state and connected ssid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const connected = try parseWifiStateView(arena,
        \\{"radio_present":true,"powered":true,"mode":"station","state":"connected","connected_ssid":"crag-test","rssi_dbm":-40}
    );
    try std.testing.expectEqualStrings("connected", connected.state);
    try std.testing.expectEqualStrings("crag-test", connected.connected_ssid.?);

    const idle = try parseWifiStateView(arena,
        \\{"radio_present":true,"powered":true,"mode":"station","state":"disconnected","connected_ssid":null,"rssi_dbm":null}
    );
    try std.testing.expectEqualStrings("disconnected", idle.state);
    try std.testing.expectEqual(@as(?[]const u8, null), idle.connected_ssid);

    try std.testing.expectError(error.BadResponse, parseWifiStateView(arena, "{\"no_state\":1}"));
    try std.testing.expectError(error.BadResponse, parseWifiStateView(arena, "[]"));
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

test "parseCommand: provisioning command group (phase 4)" {
    const ps = parseCommand(&.{ "provision", "status" });
    try std.testing.expectEqual(Action.provision_status, ps.invoke.action);

    const show = parseCommand(&.{ "wifi", "ap", "show" });
    try std.testing.expectEqual(Action.wifi_ap_show, show.invoke.action);
    const en = parseCommand(&.{ "wifi", "ap", "enable" });
    try std.testing.expectEqual(Action.wifi_ap_enable, en.invoke.action);
    const dis = parseCommand(&.{ "wifi", "ap", "disable" });
    try std.testing.expectEqual(Action.wifi_ap_disable, dis.invoke.action);
    const auto = parseCommand(&.{ "wifi", "ap", "auto" });
    try std.testing.expectEqual(Action.wifi_ap_auto, auto.invoke.action);

    const t = parseCommand(&.{"time"});
    try std.testing.expectEqual(Action.time_status, t.invoke.action);

    // Interactive factory-reset: bare command, no id, no flag.
    const interactive = parseCommand(&.{"factory-reset"});
    try std.testing.expectEqual(Action.factory_reset, interactive.invoke.action);
    try std.testing.expect(!interactive.invoke.yes_really_wipe);
    try std.testing.expectEqualStrings("", interactive.invoke.target);

    // Scripted form: flag + explicit machine-id, free flag order.
    const scripted = parseCommand(&.{ "factory-reset", "--yes-really-wipe", "0a1b2c3d4e5f" });
    try std.testing.expectEqual(Action.factory_reset, scripted.invoke.action);
    try std.testing.expect(scripted.invoke.yes_really_wipe);
    try std.testing.expectEqualStrings("0a1b2c3d4e5f", scripted.invoke.target);
}

test "parseCommand: provisioning group usage errors" {
    // The flag and the explicit id are a pair: neither alone is valid.
    try std.testing.expect(parseCommand(&.{ "factory-reset", "--yes-really-wipe" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "factory-reset", "0a1b2c3d4e5f" }) == .usage_error);
    // The flag is factory-reset-only.
    try std.testing.expect(parseCommand(&.{ "system", "--yes-really-wipe" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "wifi", "ap", "enable", "--yes-really-wipe" }) == .usage_error);
    // Unknown ap subcommand / missing subcommand.
    try std.testing.expect(parseCommand(&.{ "wifi", "ap", "frobnicate" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "wifi", "ap" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{"provision"}) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "provision", "frobnicate" }) == .usage_error);
    // Misplaced flags on the new commands.
    try std.testing.expect(parseCommand(&.{ "time", "--follow" }) == .usage_error);
    try std.testing.expect(parseCommand(&.{ "provision", "status", "--force" }) == .usage_error);

    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{ "wifi", "ap", "show" }));
    try std.testing.expectEqual(@as(u8, 0), evaluate(&.{ "factory-reset", "--yes-really-wipe", "x" }));
    try std.testing.expectEqual(@as(u8, 2), evaluate(&.{ "factory-reset", "x" }));
}

test "apBodyFor emits the tri-state override bodies" {
    try std.testing.expectEqualStrings("{\"enabled\":true}", apBodyFor(.wifi_ap_enable));
    try std.testing.expectEqualStrings("{\"enabled\":false}", apBodyFor(.wifi_ap_disable));
    try std.testing.expectEqualStrings("{\"enabled\":null}", apBodyFor(.wifi_ap_auto));
}

test "parseMachineId extracts the id, rejects redacted/garbled documents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mid = try parseMachineId(arena, "{\"board\":\"x\",\"machine_id\":\"0a1b2c3d4e5f6789\"}");
    try std.testing.expectEqualStrings("0a1b2c3d4e5f6789", mid);

    // The redacted AP-surface document has no machine_id — must error,
    // never silently confirm with garbage.
    try std.testing.expectError(error.BadResponse, parseMachineId(arena, "{\"board\":\"x\"}"));
    try std.testing.expectError(error.BadResponse, parseMachineId(arena, "{\"machine_id\":\"\"}"));
    try std.testing.expectError(error.BadResponse, parseMachineId(arena, "[]"));
}

test "formatProvisionStatus renders state + wired + wifi observations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sys = "{\"provisioning\":\"provisioning\",\"machine_id\":\"abc\"}";
    const net =
        \\{"interfaces":[
        \\ {"name":"eth0","type":"ethernet","up":true,"carrier":true,"addresses":["10.0.2.15/24"]},
        \\ {"name":"wlan0","type":"wifi","up":true,"carrier":false,"addresses":[]}],
        \\ "wan":{"order":["ethernet","wifi"]}}
    ;
    const wifi_disc = "{\"radio_present\":true,\"powered\":true,\"mode\":\"station\",\"state\":\"disconnected\",\"connected_ssid\":null,\"rssi_dbm\":null}";
    const out = try formatProvisionStatus(arena, sys, net, wifi_disc);
    const expected =
        "state    provisioning\n" ++
        "wired    eth0: carrier yes, 10.0.2.15/24\n" ++
        "wifi     disconnected\n";
    try std.testing.expectEqualStrings(expected, out);

    // Connected wifi names the ssid; AP mode is called out as the portal.
    const wifi_conn = "{\"mode\":\"station\",\"state\":\"connected\",\"connected_ssid\":\"cafe-24\"}";
    const out2 = try formatProvisionStatus(arena, "{\"provisioning\":\"provisioned\"}", net, wifi_conn);
    try std.testing.expect(std.mem.indexOf(u8, out2, "wifi     connected to cafe-24\n") != null);
    const wifi_ap = "{\"mode\":\"ap\",\"state\":\"unavailable\",\"connected_ssid\":null}";
    const out3 = try formatProvisionStatus(arena, sys, net, wifi_ap);
    try std.testing.expect(std.mem.indexOf(u8, out3, "wifi     ap (provisioning portal up)\n") != null);

    // Null observation bodies degrade, never fail the command.
    const degraded = try formatProvisionStatus(arena, sys, null, null);
    const expected_degraded =
        "state    provisioning\n" ++
        "wired    unavailable\n" ++
        "wifi     unavailable\n";
    try std.testing.expectEqualStrings(expected_degraded, degraded);

    // A system document without the provisioning field is a bad response.
    try std.testing.expectError(error.BadResponse, formatProvisionStatus(arena, "{}", null, null));
}

test "formatWifiApState renders the state and only show appends the psk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "{\"enabled\":true,\"ssid\":\"crag-4e5f67\",\"subnet\":\"192.168.223.0/24\"}";
    const with_psk = try formatWifiApState(arena, body, "0123456789abcdef");
    const expected =
        "enabled  yes\n" ++
        "ssid     crag-4e5f67\n" ++
        "subnet   192.168.223.0/24\n" ++
        "psk      0123456789abcdef\n";
    try std.testing.expectEqualStrings(expected, with_psk);

    const without = try formatWifiApState(arena, "{\"enabled\":false,\"ssid\":\"crag-4e5f67\",\"subnet\":\"192.168.223.0/24\"}", null);
    try std.testing.expect(std.mem.indexOf(u8, without, "psk") == null);
    try std.testing.expect(std.mem.indexOf(u8, without, "enabled  no\n") != null);

    try std.testing.expectError(error.BadResponse, formatWifiApState(arena, "[]", null));
}

test "wifi ap show derivation matches the daemon's (one identity everywhere)" {
    // The CLI derives the SSID/PSK with the same wifi.zig functions the
    // daemon uses, so the label story can never drift from the AP.
    var ssid_buf: [32]u8 = undefined;
    var psk_buf: [16]u8 = undefined;
    const mid = "8007a5c25ff34ce3a1a9e64e5f670000\n";
    const ssid = wifi.deriveApSsid(&ssid_buf, mid);
    try std.testing.expectEqualStrings("crag-670000", ssid);
    const psk = wifi.deriveApPsk(&psk_buf, mid);
    try std.testing.expectEqual(@as(usize, 16), psk.len);
    for (psk) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
}

test "formatTimeStatus renders synced, floor, now, and the gate verdict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const synced = try formatTimeStatus(arena, "{\"time_synced\":true}", 1700000000, 1700000100);
    const expected =
        "synced   yes\n" ++
        "floor    1700000000\n" ++
        "now      1700000100\n" ++
        "floor_ok yes\n";
    try std.testing.expectEqualStrings(expected, synced);

    const behind = try formatTimeStatus(arena, "{\"time_synced\":false}", 1700000000, 12345);
    try std.testing.expect(std.mem.indexOf(u8, behind, "synced   no\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, behind, "floor_ok no\n") != null);

    try std.testing.expectError(error.BadResponse, formatTimeStatus(arena, "[]", 0, 0));
}
