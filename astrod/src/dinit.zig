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
    const shutdown: u8 = 10; // followed by 1-byte shutdown type
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
    const pinnedstopped: u8 = 67;
    const shuttingdown: u8 = 69;
    const service_desc_err: u8 = 71;
    const service_load_err: u8 = 72;
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
    ShuttingDown,
    PinnedStopped,
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
