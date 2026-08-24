//! dinit control-socket client (dinit 0.22.0, control protocol v6).
//!
//! astrod never shells out (AD-016); privileged actions like reboot are
//! requests over dinit's control socket, keeping astrod unprivileged
//! (docs/02 §7). Protocol source of truth is the pinned cports tree
//! (cports/sources/dinit-0.22.0/v0.22.0.tar.gz — same version shipped in
//! the image rootfs, verified via the dinitctl binary's version string):
//!   src/includes/control-cmds.h       command/reply packet type bytes
//!   src/includes/control-datatypes.h  wire integer widths
//!   src/dinitctl.cc                   issue_load_service()/check_load_reply()
//!                                     and the STARTSERVICE reply handling
//!   src/includes/dinit-client.h       QUERYVERSION handshake and info-packet
//!                                     skipping (wait_for_reply())
//!   src/shutdown.cc                   SHUTDOWN command framing
//!
//! dinit memcpy's wire integers in host byte order. Client and daemon always
//! share one machine and every astro target is little-endian, so we pack
//! explicitly little-endian; this would need revisiting only for a BE port.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// dinit's system control socket: configure default SYSCONTROLSOCKET for
/// Linux (dinit-0.22.0/configure line 484) and present as a string in the
/// shipped dinitctl (build/state/images/qemu-armv7-dev/rootfs/usr/bin).
/// Access from uid astrod needs socket-permission wiring — recorded followup.
pub const default_socket_path = "/run/dinitctl";

/// Highest protocol version this client knows about (dinit 0.22.0 daemons
/// report 6). The commands we use are unchanged since protocol v1, so the
/// handshake only rejects daemons whose *minimum* exceeds this.
pub const protocol_version: u16 = 6;

// VERIFIED against the built image (build/state/images/qemu-armv7-dev/rootfs):
// /usr/lib/dinit.d (dinit-chimera 0.99.24) ships NO reboot/poweroff/shutdown
// services — the chimera services/ source tree has none either. Instead
// /usr/bin/{reboot,poweroff,halt} are symlinks to dinit's own `shutdown`
// binary (dinit-0.22.0 src/shutdown.cc), which sends cp_cmd::SHUTDOWN plus a
// one-byte shutdown_type_t over /run/dinitctl. The correct reboot path on
// this image is therefore requestShutdown(.reboot)/(.poweroff), NOT starting
// a oneshot. These names are reserved for astro-packaged pre-shutdown
// oneshots (boards/common/overlay/etc/dinit.d) if we later need audit hooks;
// startServiceByName is ready for them and for docs/06 §5.4 api_controllable.
pub const reboot_service = "sys-reboot"; // not packaged yet — see above
pub const poweroff_service = "sys-poweroff"; // not packaged yet — see above

// control-cmds.h request bytes (subset we speak).
const cmd = struct {
    const queryversion: u8 = 0;
    const findservice: u8 = 1;
    const loadservice: u8 = 2;
    const startservice: u8 = 3;
    const stopservice: u8 = 4;
    const shutdown: u8 = 10; // followed by 1-byte shutdown type
    const servicestatus5: u8 = 26; // status query, protocol v5+ (dinit 0.19.1)
};

// control-cmds.h reply bytes (subset we handle).
const rply = struct {
    const ack: u8 = 50;
    const nak: u8 = 51;
    const serviceloaderr: u8 = 54;
    const cpversion: u8 = 58;
    const servicerecord: u8 = 59;
    const noservice: u8 = 60;
    const alreadyss: u8 = 61;
    const dependents: u8 = 65;
    const pinnedstopped: u8 = 67;
    const pinnedstarted: u8 = 68;
    const shuttingdown: u8 = 69;
    /// Reply to SERVICESTATUS{,5,6}: [SERVICESTATUS][u8 reserved=0][status].
    const servicestatus: u8 = 70;
    const service_desc_err: u8 = 71;
    const service_load_err: u8 = 72;
    /// Pre-acknowledgement, issued before the main reply when the request
    /// set flag bit 7 (control.cc:342 — only the restart path asks).
    const preack: u8 = 79;
};

// Packet types >= 100 are asynchronous info (service/env events), framed as
// [type][total-length][...] and skipped by clients awaiting a reply
// (dinit-client.h wait_for_reply()).
const info_threshold: u8 = 100;

/// service-constants.h shutdown_type_t (NONE=0 is "no explicit shutdown"
/// and never sent, so it is omitted here).
pub const ShutdownType = enum(u8) {
    remain = 1,
    halt = 2,
    poweroff = 3,
    reboot = 4,
    soft_reboot = 5,
    kexec = 6,
};

/// One service's runtime status as SERVICESTATUS5 reports it: the dinit
/// service state (service-constants.h service_state_t) and the running
/// process pid (present only while the service holds a live process).
/// dinit's control protocol carries NO automatic-restart counter in any
/// status buffer — restart counts in astrod's /services surface are the
/// count of API-initiated restarts, tracked by services.zig, not read here.
pub const ServiceRuntime = struct {
    /// srvstate_t: 0 STOPPED, 1 STARTING, 2 STARTED, 3 STOPPING.
    state: u8,
    pid: ?i32,
};

/// Human token for a srvstate_t byte (service-constants.h). Total over u8 so
/// an unexpected value degrades to "unknown" rather than trapping.
pub fn stateName(state: u8) []const u8 {
    return switch (state) {
        0 => "stopped",
        1 => "starting",
        2 => "started",
        3 => "stopping",
        else => "unknown",
    };
}

/// Fixed size of the v5 status buffer (control.cc STATUS_BUFFER5_SIZE =
/// 6 + 2*sizeof(int)). int is 4 bytes on every astro target, so this is a
/// deterministic 14 — unlike the v6 buffer, whose trailing struct timespec
/// is architecture-sized. We query SERVICESTATUS5 for exactly that reason.
pub const status_buffer5_len: usize = 14;

/// fill_status_buffer5 flags byte (buffer[2]) bit4: a live process exists,
/// so buffer[6..10] is a valid pid (else it holds exit info we ignore).
const status_flag_has_pid: u8 = 16;

pub const ClientError = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    /// Daemon closed the connection mid-reply (also its BADREQ/OOM path).
    ClosedByDaemon,
    ProtocolError,
    IncompatibleVersion,
    NoService,
    ServiceLoadError,
    StartFailed,
    /// STOPSERVICE refused: NAK, or a gentle stop hit dependents.
    StopFailed,
    /// Restart NAK: the service is not currently started (control.cc
    /// service->restart() returning false) — callers that want
    /// restart-or-start semantics fall back to a plain start.
    NotStarted,
    ShuttingDown,
    PinnedStopped,
    PinnedStarted,
    NameTooLong,
};

// srvname_len_t is u16 on the wire; real service names are short, so a tight
// bound keeps the encode buffer on the stack.
pub const max_name_len = 253;
pub const load_frame_max = 3 + max_name_len;

/// [LOADSERVICE][u16 name-length LE][name] — dinitctl.cc issue_load_service().
pub fn encodeLoadService(buf: *[load_frame_max]u8, name: []const u8) error{NameTooLong}![]const u8 {
    if (name.len == 0 or name.len > max_name_len) return error.NameTooLong;
    buf[0] = cmd.loadservice;
    std.mem.writeInt(u16, buf[1..3], @intCast(name.len), .little);
    @memcpy(buf[3..][0..name.len], name);
    return buf[0 .. 3 + name.len];
}

/// [STARTSERVICE][flags][u32 handle LE] — dinitctl.cc start flow. Flags:
/// bit0 pin, bit1 gentle-stop, bit2|bit7 restart; a plain start is 0.
pub fn encodeStartService(buf: *[6]u8, handle: u32) []const u8 {
    buf[0] = cmd.startservice;
    buf[1] = 0;
    std.mem.writeInt(u32, buf[2..6], handle, .little);
    return buf[0..6];
}

/// [STOPSERVICE][flags][u32 handle LE] — control.cc process_start_stop.
/// Flags (control.cc:322-326): bit0 pin, bit1 gentle (check dependents,
/// what dinitctl sends without --force), bit2 restart-after-stop,
/// bit7 pre-ack. A plain gentle stop is 2; a restart is 2|4|128.
pub fn encodeStopService(buf: *[6]u8, handle: u32, flags: u8) []const u8 {
    buf[0] = cmd.stopservice;
    buf[1] = flags;
    std.mem.writeInt(u32, buf[2..6], handle, .little);
    return buf[0..6];
}

pub const stop_flags_gentle: u8 = 2;
pub const restart_flags: u8 = 2 | 4 | 128; // gentle | restart | pre-ack

/// [SERVICESTATUS5][u32 handle LE] — control.cc process_service_status5.
/// Chosen over SERVICESTATUS6 because the v5 reply is a fixed 14-byte buffer
/// (status_buffer5_len) on every arch, whereas v6 appends an arch-sized
/// struct timespec we would have to size at comptime to stay framed. v5
/// still carries the state + pid /services needs.
pub fn encodeServiceStatus5(buf: *[5]u8, handle: u32) []const u8 {
    buf[0] = cmd.servicestatus5;
    std.mem.writeInt(u32, buf[1..5], handle, .little);
    return buf[0..5];
}

/// [SHUTDOWN][shutdown_type] — shutdown.cc.
pub fn encodeShutdown(t: ShutdownType) [2]u8 {
    return .{ cmd.shutdown, @intFromEnum(t) };
}

pub const Client = struct {
    fd: posix.fd_t,

    /// Connect and complete the QUERYVERSION handshake (dinit-client.h
    /// check_protocol_version): reply is [CPVERSION][u16 min][u16 actual].
    pub fn connect(socket_path: []const u8) ClientError!Client {
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = @splat(0) };
        if (socket_path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..socket_path.len], socket_path);

        const rc = linux.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.ConnectFailed;
        const fd: posix.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) != .SUCCESS)
            return error.ConnectFailed;

        var client = Client{ .fd = fd };
        try client.handshake();
        return client;
    }

    pub fn deinit(self: *Client) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    fn handshake(self: *Client) ClientError!void {
        try self.writeAll(&.{cmd.queryversion});
        if (try self.readReplyByte() != rply.cpversion) return error.ProtocolError;
        var vbuf: [4]u8 = undefined;
        try self.readExact(&vbuf);
        const daemon_min = std.mem.readInt(u16, vbuf[0..2], .little);
        if (daemon_min > protocol_version) return error.IncompatibleVersion;
    }

    /// Find-or-load a service; returns its connection-scoped handle.
    /// Success reply: [SERVICERECORD][u8 state][u32 handle][u8 target-state].
    pub fn loadService(self: *Client, name: []const u8) ClientError!u32 {
        var buf: [load_frame_max]u8 = undefined;
        const frame = encodeLoadService(&buf, name) catch return error.NameTooLong;
        try self.writeAll(frame);
        switch (try self.readReplyByte()) {
            rply.servicerecord => {
                var rec: [6]u8 = undefined;
                try self.readExact(&rec);
                return std.mem.readInt(u32, rec[1..5], .little);
            },
            rply.noservice => return error.NoService,
            rply.serviceloaderr, rply.service_desc_err, rply.service_load_err => return error.ServiceLoadError,
            else => return error.ProtocolError,
        }
    }

    /// Issue a start for a loaded handle. ACK means the start was queued
    /// (dinit resolves dependencies asynchronously); ALREADYSS means the
    /// service was already started — both are success for our purposes.
    pub fn startService(self: *Client, handle: u32) ClientError!void {
        var buf: [6]u8 = undefined;
        try self.writeAll(encodeStartService(&buf, handle));
        switch (try self.readReplyByte()) {
            rply.ack, rply.alreadyss => {},
            rply.nak => return error.StartFailed,
            rply.pinnedstopped => return error.PinnedStopped,
            rply.shuttingdown => return error.ShuttingDown,
            else => return error.ProtocolError,
        }
    }

    /// Issue a GENTLE stop for a loaded handle (control.cc STOPSERVICE):
    /// ACK = stop initiated (async — dinit resolves it), ALREADYSS =
    /// already stopped; both are success. DEPENDENTS means a gentle stop
    /// would take dependents down — surfaced as StopFailed rather than
    /// escalating to force (astrod stops only leaf oneshots/services).
    pub fn stopService(self: *Client, handle: u32) ClientError!void {
        var buf: [6]u8 = undefined;
        try self.writeAll(encodeStopService(&buf, handle, stop_flags_gentle));
        switch (try self.readReplyByte()) {
            rply.ack, rply.alreadyss => {},
            rply.nak, rply.dependents => return error.StopFailed,
            rply.pinnedstarted => return error.PinnedStarted,
            rply.shuttingdown => return error.ShuttingDown,
            else => return error.ProtocolError,
        }
    }

    /// Restart a loaded handle the way dinitctl does (STOPSERVICE with
    /// the restart|pre-ack flags): PREACK arrives first (bit7), then the
    /// real reply — ACK/ALREADYSS success, NAK = service not started
    /// (NotStarted; callers wanting restart-or-start fall back to
    /// startService). The ACK means the restart was INITIATED; settling
    /// is asynchronous (callers observe the service's own readiness).
    pub fn restartService(self: *Client, handle: u32) ClientError!void {
        var buf: [6]u8 = undefined;
        try self.writeAll(encodeStopService(&buf, handle, restart_flags));
        var reply = try self.readReplyByte();
        if (reply == rply.preack) reply = try self.readReplyByte();
        switch (reply) {
            rply.ack, rply.alreadyss => {},
            rply.nak => return error.NotStarted,
            rply.dependents => return error.StopFailed,
            rply.pinnedstarted => return error.PinnedStarted,
            rply.shuttingdown => return error.ShuttingDown,
            else => return error.ProtocolError,
        }
    }

    /// Query a loaded handle's runtime status (SERVICESTATUS5). Reply is
    /// [SERVICESTATUS][u8 reserved=0][14-byte v5 status] — control.cc
    /// process_service_status5. NAK means the handle is unknown / the record
    /// vanished (surfaced as NoService). The pid is meaningful only when the
    /// flags byte's proc-running bit is set; otherwise buffer[6..] holds exit
    /// info, which we report as "no pid".
    pub fn serviceStatus(self: *Client, handle: u32) ClientError!ServiceRuntime {
        var req: [5]u8 = undefined;
        try self.writeAll(encodeServiceStatus5(&req, handle));
        switch (try self.readReplyByte()) {
            rply.servicestatus => {},
            rply.nak => return error.NoService,
            else => return error.ProtocolError,
        }
        // [reserved][status_buffer5_len]: read both; status starts at index 1.
        var raw: [1 + status_buffer5_len]u8 = undefined;
        try self.readExact(&raw);
        const pid: ?i32 = if (raw[3] & status_flag_has_pid != 0)
            std.mem.readInt(i32, raw[7..11], .little)
        else
            null;
        return .{ .state = raw[1], .pid = pid };
    }

    /// Ask dinit to shut the system down — the actual reboot/poweroff
    /// mechanism on a dinit-chimera image (see constants above).
    pub fn sendShutdown(self: *Client, t: ShutdownType) ClientError!void {
        const frame = encodeShutdown(t);
        try self.writeAll(&frame);
        switch (try self.readReplyByte()) {
            rply.ack => {},
            rply.shuttingdown => {}, // already going down: mission accomplished
            else => return error.ProtocolError,
        }
    }

    fn writeAll(self: *Client, bytes: []const u8) ClientError!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(self.fd, bytes[off..].ptr, bytes.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }

    fn readExact(self: *Client, buf: []u8) ClientError!void {
        var off: usize = 0;
        while (off < buf.len) {
            const rc = linux.read(self.fd, buf[off..].ptr, buf.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.ClosedByDaemon;
                    off += rc;
                },
                .INTR => continue,
                else => return error.ReadFailed,
            }
        }
    }

    /// First byte of the next *reply*, discarding any interleaved info
    /// packets. Starting a service we hold a handle to can deliver a
    /// SERVICEEVENT before the STARTSERVICE ack, so this is not optional.
    fn readReplyByte(self: *Client) ClientError!u8 {
        while (true) {
            var head: [1]u8 = undefined;
            try self.readExact(&head);
            if (head[0] < info_threshold) return head[0];
            var lenb: [1]u8 = undefined;
            try self.readExact(&lenb);
            // Length counts the whole packet including type + length bytes.
            if (lenb[0] < 2) return error.ProtocolError;
            var remaining: usize = lenb[0] - 2;
            var sink: [32]u8 = undefined;
            while (remaining > 0) {
                const n = @min(remaining, sink.len);
                try self.readExact(sink[0..n]);
                remaining -= n;
            }
        }
    }
};

/// One-shot connect + load + start. The future api_controllable start path
/// (docs/06 §5.4), and the reboot path if astro packages oneshot hooks.
pub fn startServiceByName(socket_path: []const u8, name: []const u8) ClientError!void {
    var client = try Client.connect(socket_path);
    defer client.deinit();
    const handle = try client.loadService(name);
    try client.startService(handle);
}

/// One-shot connect + load + gentle stop. Re-arms scripted oneshots
/// (dinit keeps them STARTED after a successful run — the phase-4
/// portal-redirect pair cycles via stop-then-start) and is half of the
/// restart fallback below.
pub fn stopServiceByName(socket_path: []const u8, name: []const u8) ClientError!void {
    var client = try Client.connect(socket_path);
    defer client.deinit();
    const handle = try client.loadService(name);
    try client.stopService(handle);
}

/// One-shot connect + load + restart-or-start: dinit's own restart
/// semantics (STOPSERVICE restart flag) when the service runs, plain
/// start when it does not. The phase-4 iwd netconfig-window swap uses
/// this so iwd re-reads main.conf along CONFIGURATION_DIRECTORY.
pub fn restartServiceByName(socket_path: []const u8, name: []const u8) ClientError!void {
    var client = try Client.connect(socket_path);
    defer client.deinit();
    const handle = try client.loadService(name);
    client.restartService(handle) catch |err| switch (err) {
        error.NotStarted => try client.startService(handle),
        else => return err,
    };
}

/// One-shot connect + SHUTDOWN — what /usr/bin/reboot and /usr/bin/poweroff
/// do on the image, minus the exec.
pub fn requestShutdown(socket_path: []const u8, t: ShutdownType) ClientError!void {
    var client = try Client.connect(socket_path);
    defer client.deinit();
    try client.sendShutdown(t);
}

// ---- tests -----------------------------------------------------------------

test "LOADSERVICE frame matches hand-computed bytes" {
    var buf: [load_frame_max]u8 = undefined;
    const frame = try encodeLoadService(&buf, "sshd");
    try std.testing.expectEqualSlices(u8, &.{ 2, 4, 0, 's', 's', 'h', 'd' }, frame);

    var long: [max_name_len + 1]u8 = @splat('a');
    try std.testing.expectError(error.NameTooLong, encodeLoadService(&buf, &long));
    try std.testing.expectError(error.NameTooLong, encodeLoadService(&buf, ""));
}

test "STARTSERVICE frame matches hand-computed bytes" {
    var buf: [6]u8 = undefined;
    const frame = encodeStartService(&buf, 0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 0x04, 0x03, 0x02, 0x01 }, frame);
}

test "STOPSERVICE frames: gentle stop and dinitctl-style restart flags" {
    var buf: [6]u8 = undefined;
    // Gentle stop: flags bit1 only (control.cc:322 "not forced").
    try std.testing.expectEqualSlices(u8, &.{ 4, 2, 0x04, 0x03, 0x02, 0x01 }, encodeStopService(&buf, 0x01020304, stop_flags_gentle));
    // Restart: gentle | restart | pre-ack — what dinitctl restart sends.
    try std.testing.expectEqualSlices(u8, &.{ 4, 0x86, 0x78, 0x56, 0x34, 0x12 }, encodeStopService(&buf, 0x12345678, restart_flags));
}

test "stop/restart against scripted replies (ack, alreadyss, preack, nak)" {
    var server: posix.fd_t = undefined;
    var client = try testClientPair(&server);
    defer client.deinit();
    defer _ = linux.close(server);

    try feed(server, &.{50}); // ACK: stop initiated
    try client.stopService(1);
    try feed(server, &.{61}); // ALREADYSS: already stopped — success
    try client.stopService(1);
    try feed(server, &.{65}); // DEPENDENTS: gentle stop refused
    try std.testing.expectError(error.StopFailed, client.stopService(1));
    try feed(server, &.{68}); // PINNEDSTARTED
    try std.testing.expectError(error.PinnedStarted, client.stopService(1));

    // Restart: PREACK precedes the real reply (bit7 requested)…
    try feed(server, &.{ 79, 61 });
    try client.restartService(2);
    // …and an interleaved info packet before the PREACK is skipped too.
    try feed(server, &.{ 100, 7, 0xaa, 0xbb, 0xcc, 0xdd, 0, 79, 50 });
    try client.restartService(2);
    // NAK = not started, the restart-or-start fallback cue.
    try feed(server, &.{ 79, 51 });
    try std.testing.expectError(error.NotStarted, client.restartService(2));
}

test "SERVICESTATUS5 frame matches hand-computed bytes" {
    var buf: [5]u8 = undefined;
    // [26][u32 handle LE].
    try std.testing.expectEqualSlices(u8, &.{ 26, 0x78, 0x56, 0x34, 0x12 }, encodeServiceStatus5(&buf, 0x12345678));
}

test "serviceStatus decodes state + pid from scripted SERVICESTATUS replies" {
    var server: posix.fd_t = undefined;
    var client = try testClientPair(&server);
    defer client.deinit();
    defer _ = linux.close(server);

    // [70][reserved=0] then 14-byte v5 status: state=2 (STARTED), target=2,
    // flags=16 (proc running), stop-reason=0, [4],[5]=0, pid=0xd431 (54321)
    // at offset 6, exit fields=0. stateName maps 2 -> "started".
    try feed(server, &.{ 70, 0, 2, 2, 16, 0, 0, 0, 0x31, 0xd4, 0, 0, 0, 0, 0, 0 });
    const rt = try client.serviceStatus(7);
    try std.testing.expectEqual(@as(u8, 2), rt.state);
    try std.testing.expectEqual(@as(?i32, 54321), rt.pid);
    try std.testing.expectEqualStrings("started", stateName(rt.state));

    // Proc-running bit clear (flags=0): no pid even though bytes 6.. are set.
    try feed(server, &.{ 70, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 });
    const rt2 = try client.serviceStatus(7);
    try std.testing.expectEqual(@as(u8, 0), rt2.state);
    try std.testing.expectEqual(@as(?i32, null), rt2.pid);
    try std.testing.expectEqualStrings("stopped", stateName(rt2.state));

    // An interleaved async info packet before the reply is skipped. The
    // reply is [70][reserved=0] + 14 status bytes (state=3 STOPPING, rest 0).
    try feed(server, &.{ 100, 7, 0xaa, 0xbb, 0xcc, 0xdd, 0, 70, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    const rt3 = try client.serviceStatus(7);
    try std.testing.expectEqualStrings("stopping", stateName(rt3.state));

    // NAK => NoService (unknown handle / record gone).
    try feed(server, &.{51});
    try std.testing.expectError(error.NoService, client.serviceStatus(9));
}

test "SHUTDOWN frames match shutdown_type_t values" {
    try std.testing.expectEqualSlices(u8, &.{ 10, 4 }, &encodeShutdown(.reboot));
    try std.testing.expectEqualSlices(u8, &.{ 10, 3 }, &encodeShutdown(.poweroff));
    try std.testing.expectEqualSlices(u8, &.{ 10, 2 }, &encodeShutdown(.halt));
}

// A scripted socketpair stands in for the daemon: replies are pre-written
// into the peer's kernel buffer, then the client's own request bytes are
// read back and checked against the expected stream. Small frames never
// fill the buffer, so nothing blocks.
fn testClientPair(server_fd: *posix.fd_t) !Client {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds)) != .SUCCESS)
        return error.SkipZigTest;
    server_fd.* = fds[1];
    return .{ .fd = fds[0] };
}

fn feed(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS) return error.TestWriteFailed;
        off += rc;
    }
}

test "handshake + load + start + shutdown against scripted replies" {
    var server: posix.fd_t = undefined;
    var client = try testClientPair(&server);
    defer client.deinit();
    defer _ = linux.close(server);

    // CPVERSION, min=1, actual=6 (LE) — as dinit 0.22.0 answers.
    try feed(server, &.{ 58, 1, 0, 6, 0 });
    try client.handshake();

    // An info packet (SERVICEEVENT: type=100, len=7, handle+event payload)
    // must be skipped, then SERVICERECORD state=1 handle=0x12345678 target=1.
    try feed(server, &.{ 100, 7, 0xaa, 0xbb, 0xcc, 0xdd, 0 });
    try feed(server, &.{ 59, 1, 0x78, 0x56, 0x34, 0x12, 1 });
    const handle = try client.loadService("sshd");
    try std.testing.expectEqual(@as(u32, 0x12345678), handle);

    try feed(server, &.{50}); // ACK
    try client.startService(handle);
    try feed(server, &.{61}); // ALREADYSS is success too
    try client.startService(handle);

    try feed(server, &.{50});
    try client.sendShutdown(.reboot);

    // The daemon side must have received exactly these request frames.
    const expected = [_]u8{0} ++ // QUERYVERSION
        [_]u8{ 2, 4, 0, 's', 's', 'h', 'd' } ++ // LOADSERVICE "sshd"
        [_]u8{ 3, 0, 0x78, 0x56, 0x34, 0x12 } ** 2 ++ // STARTSERVICE x2
        [_]u8{ 10, 4 }; // SHUTDOWN reboot
    var got: [expected.len]u8 = undefined;
    var off: usize = 0;
    while (off < got.len) {
        const rc = linux.read(server, got[off..].ptr, got.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return error.TestReadFailed;
        off += rc;
    }
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "load errors map to typed client errors" {
    var server: posix.fd_t = undefined;
    var client = try testClientPair(&server);
    defer client.deinit();
    defer _ = linux.close(server);

    try feed(server, &.{60}); // NOSERVICE
    try std.testing.expectError(error.NoService, client.loadService("nope"));
    try feed(server, &.{72}); // SERVICE_LOAD_ERR
    try std.testing.expectError(error.ServiceLoadError, client.loadService("bad"));

    // Peer EOF mid-conversation surfaces as ClosedByDaemon, not a hang.
    // (shutdown(WR), not close: a fully closed peer would EPIPE the request
    // write first and surface as WriteFailed — also a fine failure mode.)
    _ = linux.shutdown(server, linux.SHUT.WR);
    try std.testing.expectError(error.ClosedByDaemon, client.loadService("gone"));
}

test "requestShutdown surfaces ConnectFailed without a daemon" {
    // No dinit socket exists in the test environment; the router maps this
    // error to a 503 problem response.
    try std.testing.expectError(
        error.ConnectFailed,
        requestShutdown("/nonexistent/dinitctl", .reboot),
    );
}

test "live dinit integration (manual only)" {
    // A live dinit control socket is never available under `zig build test`
    // (and issuing real start/shutdown commands against a developer's init
    // would be hostile). Flip the condition to exercise this against a
    // qemu image; left compiled so it cannot rot silently.
    if (true) return error.SkipZigTest;
    var client = try Client.connect(default_socket_path);
    defer client.deinit();
    const handle = try client.loadService("sshd");
    try client.startService(handle);
}
