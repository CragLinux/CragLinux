//! Built-in mDNS announce-only responder (docs/07 §4 wired path; baked
//! phase-4 decision — no external mdns package).
//!
//! v1 scope (deliberate):
//!  - ONE UDP socket on port 5353 (unprivileged — no root needed),
//!    joined to 224.0.0.251. ff02::fb is NOT joined: a v6 socket brings a
//!    second fd + per-interface join bookkeeping for zero current
//!    consumers (installer tools on the target fleet are v4) — recorded
//!    v1 limitation, revisit with the LAN-surface work.
//!  - Announces `<instance>._crag._tcp.local` with SRV (port 8080),
//!    TXT (serial=<machine-id>, version, provisioning=<state>) and an A
//!    record; answers PTR/SRV/TXT/A queries FOR OUR NAMES ONLY,
//!    case-insensitively (RFC 6762 §16). We PARSE name compression in
//!    queries (RFC 1035 §4.1.4 pointers) but never emit it — our packets
//!    are small and self-contained.
//!  - The A record carries the device's first global IPv4 address
//!    (link.dump at answer/announce time; injectable for tests). The SRV
//!    target is `<instance>.local` — the instance label doubles as the
//!    mDNS host label so two devices never share a host name even though
//!    v1 skips probing (below). The store hostname stays an API concern.
//!  - NO probing/conflict resolution (RFC 6762 §8): the instance name
//!    is derived from the machine-id, so two devices colliding means
//!    duplicate machine-ids — a bigger problem than mDNS. Documented
//!    v1 limitation; revisit only if a fleet ever reports a collision.
//!  - NO known-answer suppression (RFC 6762 §7.1): we may re-answer a
//!    query whose known-answer section already lists us. Costs one small
//!    multicast packet; harmless, documented.
//!  - Legacy one-shot queries (source port != 5353) get a unicast reply
//!    with the query id echoed, the matched questions repeated, TTL
//!    capped at 10 s and no cache-flush bits (RFC 6762 §6.7).
//!  - Goodbye packets (TTL 0) on shutdown; re-announce on provisioning
//!    state change and every 120 s.
//!  - Gated on store api.mdns (main wires the flag; the responder never
//!    reads the store itself).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const link = @import("link.zig");
const sync = @import("sync.zig");

pub const port: u16 = 5353;
pub const multicast_v4 = [4]u8{ 224, 0, 0, 251 };
pub const service_type = "_crag._tcp.local";
pub const reannounce_interval_s: u64 = 120;
/// SRV target port: the API TCP listener (recorded deviation from
/// docs/06's :80 — unprivileged daemon, MIGRATION-NOTES §15).
pub const srv_port: u16 = 8080;
/// One TTL for the whole record set (v1 simplification: RFC 6762 §10
/// suggests 4500 s for PTR/TXT; 120 s everywhere re-converges faster
/// after an address change and matches the re-announce interval).
pub const record_ttl: u32 = 120;
/// Legacy (unicast one-shot) responses cap the TTL (RFC 6762 §6.7).
pub const legacy_ttl_cap: u32 = 10;

// DNS wire constants (RFC 1035 §3.2).
pub const TYPE_A: u16 = 1;
pub const TYPE_PTR: u16 = 12;
pub const TYPE_TXT: u16 = 16;
pub const TYPE_SRV: u16 = 33;
pub const TYPE_ANY: u16 = 255;
pub const CLASS_IN: u16 = 1;
/// mDNS cache-flush bit in the rrclass field (RFC 6762 §10.2).
pub const cache_flush: u16 = 0x8000;

/// Header flags of every packet we emit: QR=1 (response), AA=1.
const response_flags: u16 = 0x8400;
const max_name_len = 255;
/// Parsing bound; queries with more questions have the tail ignored.
const max_questions = 8;

pub const Error = error{
    OutOfMemory,
    /// Socket setup / send failure on the live paths.
    Socket,
};

/// "crag-XXXXXX": the last 6 hex chars of the machine-id — the same
/// derivation the AP SSID uses (wifi.zig deriveApSsid), so the mDNS
/// instance and the provisioning AP present one device identity.
pub fn instanceLabel(buf: *[32]u8, machine_id: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, machine_id, " \t\r\n");
    const tail = if (trimmed.len > 6) trimmed[trimmed.len - 6 ..] else trimmed;
    if (tail.len == 0 or !allHex(tail)) {
        // Fail-soft: a missing/garbled machine-id yields a fixed name
        // rather than no responder (matches system.zig's "unknown").
        const fallback = "crag-000000";
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }
    buf[0..5].* = "crag-".*;
    @memcpy(buf[5..][0..tail.len], tail);
    return buf[0 .. 5 + tail.len];
}

fn allHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// "<instance>._crag._tcp.local" — the service instance name (SRV/TXT
/// owner, PTR rdata).
pub fn serviceName(buf: *[64]u8, instance: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}." ++ service_type, .{instance}) catch unreachable;
}

/// "<instance>.local" — the host name (A owner, SRV target).
pub fn hostName(buf: *[64]u8, instance: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.local", .{instance}) catch unreachable;
}

/// TXT rdata (RFC 6763 §6): length-prefixed key=value strings. Keys per
/// docs/07 §4: serial (machine-id), version (release), provisioning.
/// Values longer than 255 are truncated (the wire format's hard cap).
pub fn buildTxt(
    allocator: std.mem.Allocator,
    serial: []const u8,
    version: []const u8,
    provisioning: []const u8,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendTxtPair(&out, allocator, "serial", serial);
    try appendTxtPair(&out, allocator, "version", version);
    try appendTxtPair(&out, allocator, "provisioning", provisioning);
    return out.toOwnedSlice(allocator);
}

fn appendTxtPair(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) error{OutOfMemory}!void {
    const max_value = 255 - (key.len + 1);
    const v = if (value.len > max_value) value[0..max_value] else value;
    try out.append(allocator, @intCast(key.len + 1 + v.len));
    try out.appendSlice(allocator, key);
    try out.append(allocator, '=');
    try out.appendSlice(allocator, v);
}

/// Encode a dotted name ("x._crag._tcp.local") as DNS wire labels.
/// No compression — announce packets are small and self-contained.
pub fn encodeName(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0) continue;
        try out.append(allocator, @intCast(@min(label.len, 63)));
        try out.appendSlice(allocator, label[0..@min(label.len, 63)]);
    }
    try out.append(allocator, 0);
    return out.toOwnedSlice(allocator);
}

pub const DecodedName = struct {
    /// Dotted form, lives in the caller's buffer.
    name: []const u8,
    /// Offset just past the name in the ORIGINAL stream (i.e. past the
    /// first compression pointer when one was followed).
    next: usize,
};

/// Decode a possibly-compressed DNS name at `start` in `msg` into dotted
/// form. Handles RFC 1035 §4.1.4 pointers with a jump bound (malicious
/// pointer loops return null, never spin). Returns null on any malformed
/// input — a bad packet is dropped, never answered.
pub fn decodeName(msg: []const u8, start: usize, buf: *[max_name_len]u8) ?DecodedName {
    var pos = start;
    var out_len: usize = 0;
    var next: ?usize = null;
    var jumps: usize = 0;
    while (true) {
        if (pos >= msg.len) return null;
        const len = msg[pos];
        if (len & 0xC0 == 0xC0) {
            if (pos + 1 >= msg.len) return null;
            if (next == null) next = pos + 2;
            const target = (@as(usize, len & 0x3F) << 8) | msg[pos + 1];
            jumps += 1;
            if (jumps > 16 or target >= msg.len) return null;
            pos = target;
            continue;
        }
        if (len & 0xC0 != 0) return null; // 0x40/0x80 label types: unsupported
        if (len == 0) {
            pos += 1;
            break;
        }
        if (pos + 1 + len > msg.len) return null;
        if (out_len + len + @intFromBool(out_len > 0) > buf.len) return null;
        if (out_len > 0) {
            buf[out_len] = '.';
            out_len += 1;
        }
        @memcpy(buf[out_len..][0..len], msg[pos + 1 ..][0..len]);
        out_len += len;
        pos += 1 + len;
    }
    return .{ .name = buf[0..out_len], .next = next orelse pos };
}

/// The records one device publishes; input to the pure packet builders.
pub const RecordSet = struct {
    /// e.g. "crag-9f03a1" (instanceLabel).
    instance: []const u8,
    /// Prebuilt TXT rdata (buildTxt).
    txt: []const u8,
    /// Current IPv4 address for the A record; null omits it.
    addr: ?[4]u8,
};

// ---- packet builders (pure, byte-vector tested) -----------------------------

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) error{OutOfMemory}!void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try out.appendSlice(allocator, &b);
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) error{OutOfMemory}!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try out.appendSlice(allocator, &b);
}

fn appendHeader(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    id: u16,
    qd: u16,
    an: u16,
    ar: u16,
) error{OutOfMemory}!void {
    try appendU16(out, allocator, id);
    try appendU16(out, allocator, response_flags);
    try appendU16(out, allocator, qd);
    try appendU16(out, allocator, an);
    try appendU16(out, allocator, 0); // NSCOUNT
    try appendU16(out, allocator, ar);
}

/// One resource record: owner name (dotted, encoded uncompressed), type,
/// class IN (+ cache-flush when `flush`), TTL, rdata.
fn appendRecord(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    rtype: u16,
    flush: bool,
    ttl: u32,
    rdata: []const u8,
) error{OutOfMemory}!void {
    const wire = try encodeName(allocator, name);
    defer allocator.free(wire);
    try out.appendSlice(allocator, wire);
    try appendU16(out, allocator, rtype);
    try appendU16(out, allocator, if (flush) CLASS_IN | cache_flush else CLASS_IN);
    try appendU32(out, allocator, ttl);
    try appendU16(out, allocator, @intCast(rdata.len));
    try out.appendSlice(allocator, rdata);
}

fn appendPtr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, svc: []const u8, ttl: u32) error{OutOfMemory}!void {
    const rdata = try encodeName(allocator, svc);
    defer allocator.free(rdata);
    // PTR is a SHARED record (RFC 6762 §10.2): never cache-flush.
    try appendRecord(out, allocator, service_type, TYPE_PTR, false, ttl, rdata);
}

fn appendSrv(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    svc: []const u8,
    host: []const u8,
    ttl: u32,
    flush: bool,
) error{OutOfMemory}!void {
    var rdata: std.ArrayList(u8) = .empty;
    defer rdata.deinit(allocator);
    try appendU16(&rdata, allocator, 0); // priority
    try appendU16(&rdata, allocator, 0); // weight
    try appendU16(&rdata, allocator, srv_port);
    const target = try encodeName(allocator, host);
    defer allocator.free(target);
    try rdata.appendSlice(allocator, target);
    try appendRecord(out, allocator, svc, TYPE_SRV, flush, ttl, rdata.items);
}

fn appendA(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    host: []const u8,
    addr: [4]u8,
    ttl: u32,
    flush: bool,
) error{OutOfMemory}!void {
    try appendRecord(out, allocator, host, TYPE_A, flush, ttl, &addr);
}

/// Build the unsolicited announcement (or, with ttl=0, the RFC 6762
/// §10.1 goodbye): PTR + SRV + TXT (+ A when an address is known), all
/// in the answer section, unique records cache-flushed.
pub fn buildAnnouncement(
    allocator: std.mem.Allocator,
    rs: RecordSet,
    ttl: u32,
) error{OutOfMemory}![]u8 {
    var sbuf: [64]u8 = undefined;
    var hbuf: [64]u8 = undefined;
    const svc = serviceName(&sbuf, rs.instance);
    const host = hostName(&hbuf, rs.instance);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const an: u16 = if (rs.addr != null) 4 else 3;
    try appendHeader(&out, allocator, 0, 0, an, 0);
    try appendPtr(&out, allocator, svc, ttl);
    try appendSrv(&out, allocator, svc, host, ttl, true);
    try appendRecord(&out, allocator, svc, TYPE_TXT, true, ttl, rs.txt);
    if (rs.addr) |a| try appendA(&out, allocator, host, a, ttl, true);
    return out.toOwnedSlice(allocator);
}

/// Which of our records a query asked for.
const Match = struct {
    ptr: bool = false,
    srv: bool = false,
    txt: bool = false,
    a: bool = false,
    // Additional-section candidates (RFC 6763 §12): a PTR answer carries
    // SRV/TXT/A along, an SRV answer carries A. Answers win over
    // additionals when both are requested.
    add_srv: bool = false,
    add_txt: bool = false,
    add_a: bool = false,
};

/// Answer a received mDNS query against our record set. Returns the
/// response packet, or null when the query asks for none of OUR names
/// (or is not a well-formed query at all — silence either way).
///
/// `legacy` (source port != 5353, RFC 6762 §6.7): echo the query id,
/// repeat the matched questions, cap TTLs at 10 s, no cache-flush bits.
/// Multicast responses use id 0 and an empty question section.
pub fn answerQuery(
    allocator: std.mem.Allocator,
    rs: RecordSet,
    query: []const u8,
    ttl: u32,
    legacy: bool,
) error{OutOfMemory}!?[]u8 {
    if (query.len < 12) return null;
    const flags = std.mem.readInt(u16, query[2..4], .big);
    if (flags & 0x8000 != 0) return null; // QR set: a response, not a query
    if ((flags >> 11) & 0xF != 0) return null; // non-standard opcode
    const qdcount = std.mem.readInt(u16, query[4..6], .big);
    if (qdcount == 0) return null;

    var sbuf: [64]u8 = undefined;
    var hbuf: [64]u8 = undefined;
    const svc = serviceName(&sbuf, rs.instance);
    const host = hostName(&hbuf, rs.instance);

    const Question = struct { buf: [max_name_len]u8, len: usize, qtype: u16 };
    var matched_qs: [max_questions]Question = undefined;
    var nq: usize = 0;

    var m: Match = .{};
    var off: usize = 12;
    var i: usize = 0;
    while (i < @min(qdcount, max_questions)) : (i += 1) {
        var nbuf: [max_name_len]u8 = undefined;
        const dec = decodeName(query, off, &nbuf) orelse return null;
        if (dec.next + 4 > query.len) return null;
        const qtype = std.mem.readInt(u16, query[dec.next..][0..2], .big);
        // Top bit of qclass is the QU (unicast-response) flag; v1 always
        // answers multicast (except legacy), so it is only masked off.
        const qclass = std.mem.readInt(u16, query[dec.next + 2 ..][0..2], .big) & 0x7FFF;
        off = dec.next + 4;
        if (qclass != CLASS_IN and qclass != TYPE_ANY) continue;

        // RFC 6762 §16: name comparison is case-insensitive.
        var hit = false;
        if (std.ascii.eqlIgnoreCase(dec.name, service_type) and (qtype == TYPE_PTR or qtype == TYPE_ANY)) {
            m.ptr = true;
            m.add_srv = true;
            m.add_txt = true;
            m.add_a = true;
            hit = true;
        }
        if (std.ascii.eqlIgnoreCase(dec.name, svc)) {
            if (qtype == TYPE_SRV or qtype == TYPE_ANY) {
                m.srv = true;
                m.add_a = true;
                hit = true;
            }
            if (qtype == TYPE_TXT or qtype == TYPE_ANY) {
                m.txt = true;
                hit = true;
            }
        }
        if (std.ascii.eqlIgnoreCase(dec.name, host) and (qtype == TYPE_A or qtype == TYPE_ANY)) {
            m.a = true;
            hit = true;
        }
        if (hit and nq < matched_qs.len) {
            const q = &matched_qs[nq];
            @memcpy(q.buf[0..dec.name.len], dec.name);
            q.len = dec.name.len;
            q.qtype = qtype;
            nq += 1;
        }
    }

    if (rs.addr == null) {
        m.a = false;
        m.add_a = false;
    }
    const an: u16 = @as(u16, @intFromBool(m.ptr)) + @intFromBool(m.srv) +
        @intFromBool(m.txt) + @intFromBool(m.a);
    if (an == 0) return null;
    const add_srv = m.add_srv and !m.srv;
    const add_txt = m.add_txt and !m.txt;
    const add_a = m.add_a and !m.a;
    const ar: u16 = @as(u16, @intFromBool(add_srv)) + @intFromBool(add_txt) + @intFromBool(add_a);

    const eff_ttl = if (legacy) @min(ttl, legacy_ttl_cap) else ttl;
    const flush = !legacy;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const id = if (legacy) std.mem.readInt(u16, query[0..2], .big) else 0;
    try appendHeader(&out, allocator, id, if (legacy) @intCast(nq) else 0, an, ar);
    if (legacy) for (matched_qs[0..nq]) |*q| {
        const wire = try encodeName(allocator, q.buf[0..q.len]);
        defer allocator.free(wire);
        try out.appendSlice(allocator, wire);
        try appendU16(&out, allocator, q.qtype);
        try appendU16(&out, allocator, CLASS_IN);
    };
    // Answers, then additionals, in a fixed record order.
    if (m.ptr) try appendPtr(&out, allocator, svc, eff_ttl);
    if (m.srv) try appendSrv(&out, allocator, svc, host, eff_ttl, flush);
    if (m.txt) try appendRecord(&out, allocator, svc, TYPE_TXT, flush, eff_ttl, rs.txt);
    if (m.a) try appendA(&out, allocator, host, rs.addr.?, eff_ttl, flush);
    if (add_srv) try appendSrv(&out, allocator, svc, host, eff_ttl, flush);
    if (add_txt) try appendRecord(&out, allocator, svc, TYPE_TXT, flush, eff_ttl, rs.txt);
    if (add_a) try appendA(&out, allocator, host, rs.addr.?, eff_ttl, flush);
    const pkt: []u8 = try out.toOwnedSlice(allocator);
    return pkt;
}

// ---- live layer -------------------------------------------------------------

/// A-record source, injectable for tests. The default walks link.dump for
/// the first global (non-loopback, non-link-local) IPv4 address.
pub const AddrFn = *const fn (allocator: std.mem.Allocator) ?[4]u8;

pub fn firstGlobalV4(allocator: std.mem.Allocator) ?[4]u8 {
    const ifaces = link.dump(allocator) catch return null;
    defer link.freeIfaces(allocator, ifaces);
    for (ifaces) |*iface| {
        if (std.mem.eql(u8, iface.name(), "lo")) continue;
        for (iface.addrs) |*a| {
            if (a.family != posix.AF.INET) continue;
            const b = a.bytes;
            if (b[0] == 127) continue;
            if (b[0] == 169 and b[1] == 254) continue; // link-local
            return .{ b[0], b[1], b[2], b[3] };
        }
    }
    return null;
}

// setsockopt plumbing (stable kernel ABI, declared locally like link.zig).
const SOL_IP: i32 = 0; // IPPROTO_IP
const IP_MULTICAST_TTL: u32 = 33;
const IP_MULTICAST_LOOP: u32 = 34;
const IP_ADD_MEMBERSHIP: u32 = 35;
const IpMreq = extern struct {
    multiaddr: u32,
    interface: u32,
};

/// Join 224.0.0.251 on whatever interface the kernel routes it to.
/// Fails with ENODEV while no configured NIC exists — cragd starts in
/// parallel with dhcpcd's first lease, so this is RETRIED from the run
/// loop rather than failing start() for good (caught live: the boot-
/// race left the responder permanently down with "Socket").
fn joinGroup(fd: posix.fd_t) bool {
    const mreq: IpMreq = .{ .multiaddr = @bitCast(multicast_v4), .interface = 0 };
    posix.setsockopt(fd, SOL_IP, IP_ADD_MEMBERSHIP, std.mem.asBytes(&mreq)) catch return false;
    return true;
}

fn openSocket(joined: *bool) error{Socket}!posix.fd_t {
    const rc = linux.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Socket;
    const fd: posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    // Coexist with any other mDNS stack bound to :5353 (dev hosts).
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch return error.Socket;
    var bind_addr: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0, // INADDR_ANY: queries arrive on whichever NIC is up
    };
    if (linux.errno(linux.bind(fd, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in))) != .SUCCESS)
        return error.Socket;
    // Group membership is best-effort here (see joinGroup): announces
    // (sends) work without it; only query RECEPTION needs the join, and
    // the run loop keeps retrying until a NIC can carry it.
    joined.* = joinGroup(fd);
    // Loop off (we would only hear ourselves), TTL 255 (RFC 6762 §11).
    posix.setsockopt(fd, SOL_IP, IP_MULTICAST_LOOP, &std.mem.toBytes(@as(c_int, 0))) catch {};
    posix.setsockopt(fd, SOL_IP, IP_MULTICAST_TTL, &std.mem.toBytes(@as(c_int, 255))) catch {};
    return fd;
}

fn nowMs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// The announce-only responder. Lifecycle: init → start (opens the
/// socket, joins the group, sends the initial announcement, spawns the
/// answer/re-announce thread) → setProvisioningState on transitions
/// (re-announces) → goodbye + deinit on shutdown.
///
/// Threading: init/start/announce/goodbye/setProvisioningState are
/// called from ONE controlling context (main / the provisioning
/// reconciler — the provision.Machine discipline); the internal thread
/// only reads the mutable TXT state under `mu`, so state updates and
/// concurrent query answering are safe.
pub const Responder = struct {
    allocator: std.mem.Allocator,
    /// Instance label, e.g. "crag-9f03a1" (owned copy).
    instance: []const u8,
    /// Release version for TXT (owned copy).
    version: []const u8,
    /// Current provisioning state for TXT; updated by setProvisioningState.
    provisioning: []const u8,
    /// Machine-id serial for TXT (owned copy).
    serial: []const u8,
    running: bool = false,
    /// 224.0.0.251 membership held (query reception). Retried from the
    /// run loop while false — see joinGroup.
    joined: std.atomic.Value(bool) = .init(false),
    /// Guards `provisioning` against the responder thread's reads.
    mu: sync.Mutex = .{},
    sock: posix.fd_t = -1,
    wake_fd: posix.fd_t = -1,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    addr_fn: AddrFn = firstGlobalV4,

    pub fn init(
        allocator: std.mem.Allocator,
        machine_id: []const u8,
        version: []const u8,
        provisioning: []const u8,
    ) error{OutOfMemory}!*Responder {
        const self = try allocator.create(Responder);
        errdefer allocator.destroy(self);
        var label_buf: [32]u8 = undefined;
        const label = instanceLabel(&label_buf, machine_id);
        self.* = .{
            .allocator = allocator,
            .instance = try allocator.dupe(u8, label),
            .version = try allocator.dupe(u8, version),
            .provisioning = provisioning, // static state strings (provision.State.jsonName)
            .serial = try allocator.dupe(u8, std.mem.trim(u8, machine_id, " \t\r\n")),
        };
        return self;
    }

    pub fn deinit(self: *Responder) void {
        self.teardown();
        const allocator = self.allocator;
        allocator.free(self.instance);
        allocator.free(self.version);
        allocator.free(self.serial);
        allocator.destroy(self);
    }

    /// Open the socket, join 224.0.0.251, spawn the loop that answers
    /// matching queries and re-announces every reannounce_interval_s,
    /// then send the initial announcement. Idempotent while running.
    pub fn start(self: *Responder) Error!void {
        if (self.thread != null) return;
        var joined = false;
        self.sock = try openSocket(&joined);
        self.joined.store(joined, .release);
        if (!joined) std.log.info("mdns: 224.0.0.251 join deferred (no configured NIC yet); retrying from the loop", .{});
        const erc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(erc) != .SUCCESS) {
            _ = linux.close(self.sock);
            self.sock = -1;
            return Error.Socket;
        }
        self.wake_fd = @intCast(erc);
        self.stop_flag.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            _ = linux.close(self.sock);
            _ = linux.close(self.wake_fd);
            self.sock = -1;
            self.wake_fd = -1;
            return Error.Socket;
        };
        self.running = true;
        self.announce() catch {};
    }

    /// Multicast the current record set (TTL 120).
    pub fn announce(self: *Responder) Error!void {
        try self.sendRecords(record_ttl);
    }

    /// Multicast the record set with TTL 0 (RFC 6762 §10.1 goodbye),
    /// then stop the loop and close the socket. Safe when not running.
    pub fn goodbye(self: *Responder) Error!void {
        if (self.sock >= 0) self.sendRecords(0) catch {};
        self.teardown();
    }

    /// Update the provisioning TXT value; re-announces when running.
    /// `state` must outlive the responder (static jsonName strings do).
    pub fn setProvisioningState(self: *Responder, state: []const u8) void {
        self.mu.lock();
        self.provisioning = state;
        self.mu.unlock();
        if (self.running) self.announce() catch {};
    }

    /// Current TXT rdata — pure, drives both announce and query answers.
    pub fn txtRdata(self: *Responder, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return buildTxt(allocator, self.serial, self.version, self.provisioning);
    }

    /// Build the current announcement/goodbye packet (also the test seam
    /// for asserting live TXT content without a socket).
    pub fn buildCurrent(self: *Responder, allocator: std.mem.Allocator, ttl: u32, addr: ?[4]u8) error{OutOfMemory}![]u8 {
        const txt = try self.txtRdata(allocator);
        defer allocator.free(txt);
        return buildAnnouncement(allocator, .{ .instance = self.instance, .txt = txt, .addr = addr }, ttl);
    }

    fn sendRecords(self: *Responder, ttl: u32) Error!void {
        if (self.sock < 0) return Error.Socket;
        const pkt = try self.buildCurrent(self.allocator, ttl, self.addr_fn(self.allocator));
        defer self.allocator.free(pkt);
        try self.sendPacket(pkt, null);
    }

    /// dst=null → the multicast group.
    fn sendPacket(self: *Responder, pkt: []const u8, dst: ?posix.sockaddr.in) Error!void {
        var to: posix.sockaddr.in = dst orelse .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(multicast_v4),
        };
        const rc = linux.sendto(self.sock, pkt.ptr, pkt.len, 0, @ptrCast(&to), @sizeOf(posix.sockaddr.in));
        if (linux.errno(rc) != .SUCCESS) return Error.Socket;
    }

    fn teardown(self: *Responder) void {
        if (self.thread) |t| {
            self.stop_flag.store(true, .release);
            const one: u64 = 1;
            _ = linux.write(self.wake_fd, @ptrCast(&one), 8);
            t.join();
            self.thread = null;
        }
        if (self.sock >= 0) {
            _ = linux.close(self.sock);
            self.sock = -1;
        }
        if (self.wake_fd >= 0) {
            _ = linux.close(self.wake_fd);
            self.wake_fd = -1;
        }
        self.running = false;
    }

    fn run(self: *Responder) void {
        var buf: [4096]u8 = undefined;
        var next_announce = nowMs() + reannounce_interval_s * 1000;
        while (!self.stop_flag.load(.acquire)) {
            const now = nowMs();
            const timeout: i32 = if (next_announce > now)
                @intCast(@min(next_announce - now, std.math.maxInt(i32)))
            else
                0;
            var pfds = [_]posix.pollfd{
                .{ .fd = self.sock, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            const n = posix.poll(&pfds, timeout) catch return;
            if (n == 0) {
                // Group-join retry (boot race: cragd can start before
                // dhcpcd's first lease gives the kernel a multicast-
                // capable route; sends work regardless, reception waits).
                if (!self.joined.load(.acquire) and joinGroup(self.sock))
                    self.joined.store(true, .release);
                // Interval re-announce (RFC 6762 tolerates unsolicited
                // refreshes; TTL 120 makes this also the cache keeper).
                self.sendRecords(record_ttl) catch {};
                next_announce = nowMs() + reannounce_interval_s * 1000;
                continue;
            }
            if (pfds[1].revents & posix.POLL.IN != 0) {
                var drain: [8]u8 = undefined;
                _ = linux.read(self.wake_fd, &drain, 8);
                continue; // re-check stop_flag
            }
            if (pfds[0].revents & posix.POLL.IN == 0) continue;
            var src: posix.sockaddr.in = undefined;
            var slen: linux.socklen_t = @sizeOf(posix.sockaddr.in);
            const rc = linux.recvfrom(self.sock, &buf, buf.len, 0, @ptrCast(&src), &slen);
            if (linux.errno(rc) != .SUCCESS) continue;
            self.handlePacket(buf[0..@as(usize, rc)], src);
        }
    }

    fn handlePacket(self: *Responder, pkt: []const u8, src: posix.sockaddr.in) void {
        const allocator = self.allocator;
        const legacy = std.mem.bigToNative(u16, src.port) != port;
        const txt = self.txtRdata(allocator) catch return;
        defer allocator.free(txt);
        const rs: RecordSet = .{
            .instance = self.instance,
            .txt = txt,
            .addr = self.addr_fn(allocator),
        };
        const resp = (answerQuery(allocator, rs, pkt, record_ttl, legacy) catch return) orelse return;
        defer allocator.free(resp);
        // Legacy one-shot resolvers get a unicast reply; mDNS-proper
        // queries are answered on the group (RFC 6762 §6.7 / §6).
        self.sendPacket(resp, if (legacy) src else null) catch {};
    }
};

// ---- tests -----------------------------------------------------------------

test "instanceLabel derives crag-<last 6 hex> and fails soft" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "crag-9f03a1",
        instanceLabel(&buf, "e5c1770f8ffb4dc7a276869f9f03a1\n"),
    );
    // Short-but-hex ids use what exists.
    try std.testing.expectEqualStrings("crag-ab12", instanceLabel(&buf, "ab12"));
    // Garbage/missing ids yield the fixed fallback, never junk.
    try std.testing.expectEqualStrings("crag-000000", instanceLabel(&buf, "unknown"));
    try std.testing.expectEqualStrings("crag-000000", instanceLabel(&buf, ""));
}

test "serviceName/hostName compose the owner names" {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    try std.testing.expectEqualStrings("crag-9f03a1._crag._tcp.local", serviceName(&b1, "crag-9f03a1"));
    try std.testing.expectEqualStrings("crag-9f03a1.local", hostName(&b2, "crag-9f03a1"));
}

test "buildTxt renders RFC 6763 length-prefixed pairs" {
    const txt = try buildTxt(std.testing.allocator, "abc123", "0.2.0", "provisioning");
    defer std.testing.allocator.free(txt);
    // serial=abc123 | version=0.2.0 | provisioning=provisioning
    const want = "\x0dserial=abc123" ++ "\x0dversion=0.2.0" ++ "\x19provisioning=provisioning";
    try std.testing.expectEqualStrings(want, txt);
}

test "buildTxt truncates oversized values at the 255-byte string cap" {
    const big = "x" ** 300;
    const txt = try buildTxt(std.testing.allocator, big, "v", "factory");
    defer std.testing.allocator.free(txt);
    // First string: len byte 255, "serial=" + 248 x's.
    try std.testing.expectEqual(@as(u8, 255), txt[0]);
    try std.testing.expectEqualStrings("serial=", txt[1..8]);
    try std.testing.expectEqual(@as(u8, 'x'), txt[255]);
    try std.testing.expect(txt[256] != 'x'); // next pair's length byte
}

test "encodeName produces wire labels with a root terminator" {
    const wire = try encodeName(std.testing.allocator, "crag-9f03a1._crag._tcp.local");
    defer std.testing.allocator.free(wire);
    const want = "\x0bcrag-9f03a1" ++ "\x05_crag" ++ "\x04_tcp" ++ "\x05local" ++ "\x00";
    try std.testing.expectEqualStrings(want, wire);
}

// Shared wire fragments for the byte-vector tests below (hand-computed).
const svc_type_wire = "\x05_crag" ++ "\x04_tcp" ++ "\x05local" ++ "\x00"; // 18 bytes
const svc_wire = "\x0bcrag-9f03a1" ++ svc_type_wire; // 30 bytes
const host_wire = "\x0bcrag-9f03a1" ++ "\x05local" ++ "\x00"; // 19 bytes
// TXT rdata for ("abc","1.0","factory"): 11 + 12 + 21 = 44 bytes.
const txt_rdata = "\x0aserial=abc" ++ "\x0bversion=1.0" ++ "\x14provisioning=factory";

test "buildAnnouncement full packet byte vector" {
    const a = std.testing.allocator;
    const txt = try buildTxt(a, "abc", "1.0", "factory");
    defer a.free(txt);
    const pkt = try buildAnnouncement(a, .{
        .instance = "crag-9f03a1",
        .txt = txt,
        .addr = .{ 192, 168, 1, 2 },
    }, record_ttl);
    defer a.free(pkt);

    const ttl_bytes = "\x00\x00\x00\x78"; // 120
    const want =
        // id=0, flags 0x8400 (QR|AA), QD=0, AN=4, NS=0, AR=0
        "\x00\x00" ++ "\x84\x00" ++ "\x00\x00" ++ "\x00\x04" ++ "\x00\x00" ++ "\x00\x00" ++
        // PTR _crag._tcp.local -> crag-9f03a1._crag._tcp.local (no flush: shared)
        svc_type_wire ++ "\x00\x0c" ++ "\x00\x01" ++ ttl_bytes ++ "\x00\x1e" ++ svc_wire ++
        // SRV crag-9f03a1._crag._tcp.local (flush) prio 0 weight 0 port 8080 -> crag-9f03a1.local
        svc_wire ++ "\x00\x21" ++ "\x80\x01" ++ ttl_bytes ++ "\x00\x19" ++
        "\x00\x00" ++ "\x00\x00" ++ "\x1f\x90" ++ host_wire ++
        // TXT (flush)
        svc_wire ++ "\x00\x10" ++ "\x80\x01" ++ ttl_bytes ++ "\x00\x2c" ++ txt_rdata ++
        // A crag-9f03a1.local (flush) 192.168.1.2
        host_wire ++ "\x00\x01" ++ "\x80\x01" ++ ttl_bytes ++ "\x00\x04" ++ "\xc0\xa8\x01\x02";
    try std.testing.expectEqualSlices(u8, want, pkt);
}

test "buildAnnouncement goodbye (ttl 0) and address-less (3 answers)" {
    const a = std.testing.allocator;
    const goodbye_pkt = try buildAnnouncement(a, .{
        .instance = "crag-9f03a1",
        .txt = txt_rdata,
        .addr = .{ 192, 168, 1, 2 },
    }, 0);
    defer a.free(goodbye_pkt);
    // Same shape, every TTL zeroed: check the PTR record's TTL bytes.
    const ptr_ttl_off = 12 + svc_type_wire.len + 4;
    try std.testing.expectEqualSlices(u8, "\x00\x00\x00\x00", goodbye_pkt[ptr_ttl_off..][0..4]);

    const no_addr = try buildAnnouncement(a, .{
        .instance = "crag-9f03a1",
        .txt = txt_rdata,
        .addr = null,
    }, record_ttl);
    defer a.free(no_addr);
    try std.testing.expectEqual(@as(u8, 3), no_addr[7]); // ANCOUNT low byte
    try std.testing.expect(std.mem.indexOf(u8, no_addr, host_wire ++ "\x00\x01") == null); // no A record
}

test "decodeName: plain, compressed, and hostile inputs" {
    var buf: [max_name_len]u8 = undefined;

    // Plain name.
    const plain = "\x03foo\x05local\x00";
    const d1 = decodeName(plain, 0, &buf).?;
    try std.testing.expectEqualStrings("foo.local", d1.name);
    try std.testing.expectEqual(plain.len, d1.next);

    // Compression: label + pointer back to offset 4 ("\x05local\x00").
    const msg = "\x00\x00\x00\x00" ++ "\x05local\x00" ++ "\x03foo" ++ "\xc0\x04";
    const d2 = decodeName(msg, 11, &buf).?;
    try std.testing.expectEqualStrings("foo.local", d2.name);
    try std.testing.expectEqual(msg.len, d2.next); // past the pointer, not the target

    // Pointer loop: must bail, not spin.
    const loop = "\xc0\x00";
    try std.testing.expect(decodeName(loop, 0, &buf) == null);
    // Truncated label.
    try std.testing.expect(decodeName("\x0bshort", 0, &buf) == null);
    // Pointer past the end.
    try std.testing.expect(decodeName("\xc0\x63", 0, &buf) == null);
}

fn testRecordSet() RecordSet {
    return .{ .instance = "crag-9f03a1", .txt = txt_rdata, .addr = .{ 192, 168, 1, 2 } };
}

test "answerQuery: PTR service query yields PTR answer + SRV/TXT/A additionals" {
    const a = std.testing.allocator;
    const query = "\x00\x00" ++ "\x00\x00" ++ "\x00\x01" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++
        svc_type_wire ++ "\x00\x0c" ++ "\x00\x01";
    const resp = (try answerQuery(a, testRecordSet(), query, record_ttl, false)).?;
    defer a.free(resp);

    const ttl_bytes = "\x00\x00\x00\x78";
    const want =
        "\x00\x00" ++ "\x84\x00" ++ "\x00\x00" ++ "\x00\x01" ++ "\x00\x00" ++ "\x00\x03" ++
        svc_type_wire ++ "\x00\x0c" ++ "\x00\x01" ++ ttl_bytes ++ "\x00\x1e" ++ svc_wire ++
        svc_wire ++ "\x00\x21" ++ "\x80\x01" ++ ttl_bytes ++ "\x00\x19" ++
        "\x00\x00" ++ "\x00\x00" ++ "\x1f\x90" ++ host_wire ++
        svc_wire ++ "\x00\x10" ++ "\x80\x01" ++ ttl_bytes ++ "\x00\x2c" ++ txt_rdata ++
        host_wire ++ "\x00\x01" ++ "\x80\x01" ++ ttl_bytes ++ "\x00\x04" ++ "\xc0\xa8\x01\x02";
    try std.testing.expectEqualSlices(u8, want, resp);
}

test "answerQuery: compressed and case-insensitive query names" {
    const a = std.testing.allocator;
    // Q1 at offset 12: "_CRAG._TCP.LOCAL" PTR (case-insensitive match).
    // Q2: "CRAG-9F03A1" + pointer to offset 12 (the service-type name)
    //     with qtype SRV — exercises compression inside a parsed name.
    const q1_name = "\x05_CRAG" ++ "\x04_TCP" ++ "\x05LOCAL" ++ "\x00";
    const query = "\x00\x00" ++ "\x00\x00" ++ "\x00\x02" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++
        q1_name ++ "\x00\x0c" ++ "\x00\x01" ++
        "\x0bCRAG-9F03A1" ++ "\xc0\x0c" ++ "\x00\x21" ++ "\x00\x01";
    const resp = (try answerQuery(a, testRecordSet(), query, record_ttl, false)).?;
    defer a.free(resp);

    // PTR + SRV answered; TXT + A ride along as additionals.
    try std.testing.expectEqual(@as(u8, 2), resp[7]); // ANCOUNT
    try std.testing.expectEqual(@as(u8, 2), resp[11]); // ARCOUNT
    try std.testing.expect(std.mem.indexOf(u8, resp, svc_wire ++ "\x00\x21") != null); // SRV present
    try std.testing.expect(std.mem.indexOf(u8, resp, svc_wire ++ "\x00\x10") != null); // TXT additional
    try std.testing.expect(std.mem.indexOf(u8, resp, host_wire ++ "\x00\x01") != null); // A additional
}

test "answerQuery: silence for others' names, responses, and foreign qtypes" {
    const a = std.testing.allocator;
    // A name that is not ours.
    const other = "\x00\x00" ++ "\x00\x00" ++ "\x00\x01" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++
        "\x05other" ++ "\x05local" ++ "\x00" ++ "\x00\x01" ++ "\x00\x01";
    try std.testing.expect((try answerQuery(a, testRecordSet(), other, record_ttl, false)) == null);

    // Our name, but a response packet (QR set) — never answer answers.
    const not_query = "\x00\x00" ++ "\x84\x00" ++ "\x00\x01" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++
        svc_type_wire ++ "\x00\x0c" ++ "\x00\x01";
    try std.testing.expect((try answerQuery(a, testRecordSet(), not_query, record_ttl, false)) == null);

    // Our service name with a qtype we do not own (MX=15).
    const mx = "\x00\x00" ++ "\x00\x00" ++ "\x00\x01" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++
        svc_wire ++ "\x00\x0f" ++ "\x00\x01";
    try std.testing.expect((try answerQuery(a, testRecordSet(), mx, record_ttl, false)) == null);

    // Truncated garbage.
    try std.testing.expect((try answerQuery(a, testRecordSet(), "\x00\x00\x00", record_ttl, false)) == null);
}

test "answerQuery: A query for the host name with and without an address" {
    const a = std.testing.allocator;
    const query = "\x00\x00" ++ "\x00\x00" ++ "\x00\x01" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++
        host_wire ++ "\x00\x01" ++ "\x00\x01";
    const resp = (try answerQuery(a, testRecordSet(), query, record_ttl, false)).?;
    defer a.free(resp);
    try std.testing.expectEqual(@as(u8, 1), resp[7]); // just the A answer
    try std.testing.expectEqual(@as(u8, 0), resp[11]);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\xc0\xa8\x01\x02"));

    // No address known → nothing to say.
    var rs = testRecordSet();
    rs.addr = null;
    try std.testing.expect((try answerQuery(a, rs, query, record_ttl, false)) == null);
}

test "answerQuery legacy: id echo, question repeat, TTL cap, no cache-flush" {
    const a = std.testing.allocator;
    const query = "\x12\x34" ++ "\x00\x00" ++ "\x00\x01" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++
        host_wire ++ "\x00\x01" ++ "\x00\x01";
    const resp = (try answerQuery(a, testRecordSet(), query, record_ttl, true)).?;
    defer a.free(resp);
    const want =
        // id echoed, QD=1 (question repeated), AN=1
        "\x12\x34" ++ "\x84\x00" ++ "\x00\x01" ++ "\x00\x01" ++ "\x00\x00" ++ "\x00\x00" ++
        host_wire ++ "\x00\x01" ++ "\x00\x01" ++
        // class WITHOUT cache-flush, TTL capped at 10
        host_wire ++ "\x00\x01" ++ "\x00\x01" ++ "\x00\x00\x00\x0a" ++ "\x00\x04" ++ "\xc0\xa8\x01\x02";
    try std.testing.expectEqualSlices(u8, want, resp);
}

test "Responder: identity wiring and TXT state updates in built packets" {
    var r = try Responder.init(std.testing.allocator, "e5c1770f9f03a1\n", "0.2.0", "factory");
    defer r.deinit();
    try std.testing.expectEqualStrings("crag-9f03a1", r.instance);

    const txt1 = try r.txtRdata(std.testing.allocator);
    defer std.testing.allocator.free(txt1);
    try std.testing.expect(std.mem.indexOf(u8, txt1, "provisioning=factory") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt1, "serial=e5c1770f9f03a1") != null);

    // State change flows into the next announcement (not running: no
    // socket send is attempted, the TXT swap alone).
    r.setProvisioningState("provisioning");
    const pkt = try r.buildCurrent(std.testing.allocator, record_ttl, .{ 10, 0, 0, 2 });
    defer std.testing.allocator.free(pkt);
    try std.testing.expect(std.mem.indexOf(u8, pkt, "provisioning=provisioning") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkt, "provisioning=factory") == null);

    // Not started: announce/goodbye degrade cleanly.
    try std.testing.expectError(Error.Socket, r.announce());
    try r.goodbye(); // no-op teardown
}

fn fixedTestAddr(_: std.mem.Allocator) ?[4]u8 {
    return .{ 192, 0, 2, 1 };
}

test "Responder live socket: start, state re-announce, goodbye (skips sandboxed)" {
    var r = try Responder.init(std.testing.allocator, "e5c1770f9f03a1", "0.2.0", "factory");
    defer r.deinit();
    r.addr_fn = fixedTestAddr;
    r.start() catch |err| switch (err) {
        // Environments without multicast/bind privileges skip.
        Error.Socket => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expect(r.running);
    r.setProvisioningState("provisioning"); // re-announces on the live socket
    try r.goodbye();
    try std.testing.expect(!r.running);
    // Idempotent: a second goodbye and the deinit teardown are safe.
    try r.goodbye();
}
