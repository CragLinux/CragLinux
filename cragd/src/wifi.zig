//! Wifi backend over iwd's D-Bus surface (net.connman.iwd), AD-015: iwd
//! manages wifi ONLY (EnableNetworkConfiguration=false via the overlay's
//! /etc/iwd/main.conf); dhcpcd owns addressing; cragd is the policy
//! brain. iwd is an ObjectManager at "/" (iwd-3.12 src/main.c) with
//! Adapter/Device/Station/Network/KnownNetwork objects under
//! /net/connman/iwd — consumed via bus.getManagedObjects /
//! matchInterfacesAdded / matchPropertiesChangedTree.
//!
//! Everything below is verified against the PINNED iwd-3.12 source:
//!  - interface names: src/dbus.h:25-53
//!  - Station: Scan/GetOrderedNetworks ("a(on)", signal in 0.01-dBm mBm
//!    units — src/station.c:5295-5326, scan.c NL80211_BSS_SIGNAL_MBM) and
//!    properties State "s" / Scanning "b" / ConnectedNetwork "o"
//!  - StationDiagnostic.GetDiagnostics → a{sv}, key "RSSI" type 'n' in
//!    plain dBm (src/diagnostic.c:42-46, src/station.c:5600)
//!  - Network: Connect() (no args), Name "s", Type "s", Connected "b",
//!    Device "o", KnownNetwork "o" (present only while a profile exists —
//!    src/network.c:2165-2185)
//!  - KnownNetwork: Forget(), Name "s", Type "s"
//!    (src/knownnetworks.c:730-736)
//!  - Device: Name/Address "s", Powered "b", Adapter "o", Mode "s"
//!    ("station"/"ap"/"ad-hoc"/... — src/device.c:257-268, mode strings
//!    from netdev_iftype_to_string)
//!
//! Persistence split: the CONNECTION PROFILE lives in the store
//! (network.wifi.connection {ssid, psk}); cragd renders it as an iwd
//! known-network file <ssid>.psk into /data/net/iwd (iwd's
//! STATE_DIRECTORY, pointed there by the shadow dinit service). iwd
//! watches that directory (iwd-3.12 src/knownnetworks.c:1130,
//! l_dir_watch) so a rendered file is picked up without a restart and
//! enables autoconnect. forget() deletes both the store field and the
//! file.
//!
//! Threading/locking contract:
//!  - self.mu guards the mirrored object model. It is a LEAF lock next to
//!    bus.mu: signal callbacks (bus thread, bus.mu HELD) take self.mu;
//!    therefore NOTHING in this file calls into Bus while holding
//!    self.mu (lock inversion → deadlock). Copy paths out first.
//!  - ops.Registry and events.EventBus are leaf locks too (their own
//!    docs) and safe from signal callbacks.
//!
//! Degraded-not-error semantics (docs/06 §7): connect() persisting the
//! desired profile ALWAYS succeeds when the input is valid — an
//! unreachable/wrong-password network is NOT an API error; live progress
//! flows via `network.wifi.state` events as iwd's Station.State moves.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const bus_mod = @import("bus.zig");
const store_mod = @import("store.zig");
const ops = @import("ops.zig");
const events_mod = @import("events.zig");
const sync = @import("sync.zig");
const fsutil = @import("fsutil.zig");

pub const iwd_service = "net.connman.iwd";
pub const iwd_manager_path = "/";
pub const iwd_state_dir = "/data/net/iwd";
/// Every iwd object lives under this namespace (iwd-3.12 src/dbus.h:53).
pub const iwd_path_namespace = "/net/connman/iwd";

// Interface names, iwd-3.12 src/dbus.h.
const device_interface = "net.connman.iwd.Device";
const station_interface = "net.connman.iwd.Station";
const network_interface = "net.connman.iwd.Network";
const known_network_interface = "net.connman.iwd.KnownNetwork";
const station_diagnostic_interface = "net.connman.iwd.StationDiagnostic";
/// AP mode (iwd-3.12 src/dbus.h:36 IWD_AP_INTERFACE); registered on the
/// Device path while Device.Mode == "ap".
const ap_interface = "net.connman.iwd.AccessPoint";

/// Event types published here (followup: mirror as events.types consts).
pub const event_wifi_state = events_mod.types.network_wifi_state;
pub const event_wifi_scan_done = events_mod.types.network_wifi_scan_done;

/// iwd object paths are /net/connman/iwd/<phy>/<ifindex>/<ssid-hex>_<sec>
/// — ssid-hex is at most 64 chars, so 256 covers everything.
const max_path_len = 256;
/// How long connect() waits for a just-scanned ssid to appear before
/// falling back to iwd autoconnect (profile is already on disk).
const connect_scan_wait_ms: u64 = 5000;
/// AP→station flip: how long tryConnect waits for the Station interface
/// to (re)register after Device.Mode="station" before treating the
/// radio as station-less (see tryConnect; iwd's InterfacesAdded races
/// the flip on fast boards).
const station_register_wait_ms: u64 = 3000;

pub const Error = error{
    NotImplemented,
    OutOfMemory,
    /// No wifi radio object exists on the bus (board without radios, or
    /// iwd down) — the API maps this to a degraded GET /network/wifi,
    /// not an HTTP error.
    NoRadio,
    /// iwd rejected the operation; bus.lastDbusError() has the name.
    IwdError,
    /// The daemon has no D-Bus connection (503 surface).
    BusUnavailable,
    /// ssid/psk failed shape validation (400 surface) — nothing was
    /// persisted.
    InvalidArgument,
    /// Persisting the desired state (store document or rendered
    /// known-network file) failed — a real 5xx, unlike an unreachable
    /// network which is degraded-but-successful.
    StoreFailed,
};

pub const Security = enum { open, psk, @"8021x" };

/// One scan result for GET /network/wifi/networks.
pub const NetworkInfo = struct {
    ssid: []const u8,
    /// Signal strength in dBm (iwd reports 0.01-dBm units on
    /// GetOrderedNetworks; converted here).
    signal_dbm: i16,
    security: Security,
    /// An iwd KnownNetwork exists (profile present).
    known: bool,
    connected: bool,
};

pub const Mode = enum { station, ap, off };

/// Radio/connection state for GET /network/wifi.
pub const State = struct {
    /// A Device object exists on the bus.
    radio_present: bool,
    powered: bool,
    mode: Mode,
    /// Station only: null when disconnected.
    connected_ssid: ?[]const u8,
    rssi_dbm: ?i16,
    /// Station state string as iwd reports it ("connected", "roaming",
    /// "disconnected", ...); "unavailable" when no radio.
    station_state: []const u8,
};

// ---- known-network profile rendering (pure, unit-tested) --------------------

/// iwd's Type strings are security_to_str (iwd-3.12 src/common.c:35):
/// "open"/"wep"/"psk"/"8021x". WEP is unsupported by iwd itself — mapped
/// to null and filtered out of listings.
fn securityFromType(t: []const u8) ?Security {
    if (std.mem.eql(u8, t, "open")) return .open;
    if (std.mem.eql(u8, t, "psk")) return .psk;
    if (std.mem.eql(u8, t, "8021x")) return .@"8021x";
    return null;
}

/// Validate a connection secret: empty (open network), a 64-char hex raw
/// PSK, or an 8..63-char WPA passphrase; control bytes are rejected (the
/// value is written into a line-oriented l_settings file).
pub fn validatePsk(psk: []const u8) error{InvalidArgument}!void {
    if (psk.len == 0) return; // open network
    for (psk) |b| {
        if (b < 0x20 or b == 0x7f) return error.InvalidArgument;
    }
    if (isRawPsk(psk)) return;
    if (psk.len < 8 or psk.len > 63) return error.InvalidArgument;
}

fn isRawPsk(psk: []const u8) bool {
    if (psk.len != 64) return false;
    for (psk) |b| {
        if (!std.ascii.isHex(b)) return false;
    }
    return true;
}

/// iwd's ssid→filename encoding, matched byte-for-byte against iwd-3.12
/// src/storage.c:278 storage_get_network_file_path(): the name is used
/// verbatim iff every byte is alphanumeric or one of "-_ " (C-locale
/// isalnum); otherwise it is "=" + lowercase hex of the raw ssid bytes
/// (l_util_hexstring, ell/util.c:474 — lowercase digits). Extension is
/// security_to_str: .open/.psk/.8021x.
pub fn ssidFileName(
    allocator: std.mem.Allocator,
    ssid: []const u8,
    security: Security,
) error{OutOfMemory}![]u8 {
    var needs_hex = false;
    for (ssid) |b| {
        if (!(std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == ' ')) {
            needs_hex = true;
            break;
        }
    }
    const ext = @tagName(security);
    if (!needs_hex) return std.fmt.allocPrint(allocator, "{s}.{s}", .{ ssid, ext });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const digits = "0123456789abcdef";
    try out.append(allocator, '=');
    for (ssid) |b| {
        try out.append(allocator, digits[b >> 4]);
        try out.append(allocator, digits[b & 0xf]);
    }
    try out.append(allocator, '.');
    try out.appendSlice(allocator, ext);
    return out.toOwnedSlice(allocator);
}

/// Render the known-network file body. Passphrase is PREFERRED over
/// PreSharedKey: iwd derives the PSK itself (PBKDF2 over ssid+passphrase)
/// and WPA3-Personal/SAE REQUIRES the passphrase — a raw PSK cannot do
/// SAE (iwd-3.12 src/iwd.network.rst:201-219: "Required when connecting
/// to WPA3-Personal (SAE) networks"). PreSharedKey is emitted only when
/// the caller supplied a literal 64-hex raw key. An empty psk renders an
/// open-network profile (autoconnect marker only).
pub fn renderProfile(
    allocator: std.mem.Allocator,
    psk: []const u8,
) error{ OutOfMemory, InvalidArgument }![]u8 {
    try validatePsk(psk);
    if (psk.len == 0) return allocator.dupe(u8, "[Settings]\nAutoConnect=true\n");
    if (isRawPsk(psk))
        return std.fmt.allocPrint(allocator, "[Security]\nPreSharedKey={s}\n", .{psk});
    return std.fmt.allocPrint(allocator, "[Security]\nPassphrase={s}\n", .{psk});
}

/// Render + atomically install the known-network file for (ssid, psk)
/// into `dir` (0600, tmp+rename; the ".tmp" suffix is invisible to iwd's
/// dir watch, which only reacts to .open/.psk/.8021x). Creates `dir`
/// 0700 if missing (tmpfiles owns it on real images; tests use /tmp).
pub fn writeProfile(
    allocator: std.mem.Allocator,
    dir: []const u8,
    ssid: []const u8,
    psk: []const u8,
) error{ OutOfMemory, InvalidArgument, WriteFailed }!void {
    if (ssid.len == 0 or ssid.len > 32) return error.InvalidArgument;
    const sec: Security = if (psk.len == 0) .open else .psk;
    const name = try ssidFileName(allocator, ssid, sec);
    defer allocator.free(name);
    const content = try renderProfile(allocator, psk);
    defer allocator.free(content);

    mkdirAll(dir, 0o700);
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }) catch
        return error.OutOfMemory;
    defer allocator.free(path);
    const tmp = std.fmt.allocPrint(allocator, "{s}.tmp", .{path}) catch
        return error.OutOfMemory;
    defer allocator.free(tmp);
    try writeFileMode(tmp, content, 0o600);
    fsutil.rename(tmp, path) catch return error.WriteFailed;
}

/// Remove the rendered profile(s) for `ssid` — both the .psk and .open
/// variants (v1 renders only these two). Missing files are fine.
pub fn removeProfiles(allocator: std.mem.Allocator, dir: []const u8, ssid: []const u8) void {
    const secs = [_]Security{ .psk, .open };
    for (secs) |sec| {
        const name = ssidFileName(allocator, ssid, sec) catch return;
        defer allocator.free(name);
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }) catch return;
        defer allocator.free(path);
        fsutil.unlink(path) catch {};
    }
}

fn mkdirAll(path: []const u8, mode: linux.mode_t) void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') mkdirOne(path[0..i], mode);
    }
    mkdirOne(path, mode);
}

fn mkdirOne(path: []const u8, mode: linux.mode_t) void {
    const path_z = posix.toPosixPath(path) catch return;
    _ = linux.mkdirat(linux.AT.FDCWD, &path_z, mode); // EEXIST et al: fine
}

/// Like fsutil.writeFileSync but with an explicit mode — profiles carry
/// secrets and must be 0600 (fsutil's default is 0644).
fn writeFileMode(path: []const u8, bytes: []const u8, mode: linux.mode_t) error{WriteFailed}!void {
    const path_z = posix.toPosixPath(path) catch return error.WriteFailed;
    const rc = linux.openat(
        linux.AT.FDCWD,
        &path_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        mode,
    );
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const w = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(w) != .SUCCESS) return error.WriteFailed;
        off += w;
    }
    if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.WriteFailed;
}

// ---- mirrored iwd object model (pure, unit-tested) --------------------------
// A typed mirror of the iwd tree, fed by GetManagedObjects at startup and
// kept fresh by InterfacesAdded/Removed + PropertiesChanged signals. All
// strings are gpa-owned copies; on OOM a mutation keeps the old value
// (never crashes the bus thread).

fn parseMode(s: []const u8) Mode {
    if (std.mem.eql(u8, s, "station")) return .station;
    if (std.mem.eql(u8, s, "ap")) return .ap;
    return .off; // "ad-hoc"/"p2p-*"/"unknown": not a mode v1 exposes
}

const Device = struct {
    path: []u8,
    name: []u8 = &.{},
    powered: bool = false,
    mode: Mode = .off,
    has_station: bool = false,
    station_state: []u8 = &.{},
    scanning: bool = false,
    /// Object path of the connected Network, per Station.ConnectedNetwork.
    connected_network: ?[]u8 = null,
    /// The AccessPoint interface exists on this device (Mode == "ap").
    has_ap: bool = false,
    /// AccessPoint.Started ("b", iwd-3.12 src/ap.c:4727).
    ap_started: bool = false,
};

const Net = struct {
    path: []u8,
    name: []u8 = &.{},
    security: ?Security = null,
    connected: bool = false,
    /// The KnownNetwork property exists only while a profile is on disk
    /// (iwd-3.12 src/network.c network_property_get_known); presence ==
    /// known, invalidation == forgotten.
    known: bool = false,
    device: []u8 = &.{},
};

const Known = struct {
    path: []u8,
    name: []u8 = &.{},
    security: ?Security = null,
};

/// Result of applying a PropertiesChanged batch: effects the caller
/// (bus-thread handler) turns into events/operation completion. Pure
/// data so the model stays testable without a bus.
const ApplyResult = struct {
    station_state_changed: bool = false,
    /// Station.Scanning flipped true→false (scan completion edge).
    scan_finished: bool = false,
    /// AccessPoint.Started changed value (AP came up / went down).
    ap_started_changed: bool = false,
};

const Model = struct {
    gpa: std.mem.Allocator,
    devices: std.ArrayList(Device) = .empty,
    nets: std.ArrayList(Net) = .empty,
    knowns: std.ArrayList(Known) = .empty,

    fn deinit(self: *Model) void {
        for (self.devices.items) |*d| freeDevice(self.gpa, d);
        self.devices.deinit(self.gpa);
        for (self.nets.items) |*n| freeNet(self.gpa, n);
        self.nets.deinit(self.gpa);
        for (self.knowns.items) |*k| freeKnown(self.gpa, k);
        self.knowns.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeDevice(gpa: std.mem.Allocator, d: *Device) void {
        gpa.free(d.path);
        gpa.free(d.name);
        gpa.free(d.station_state);
        if (d.connected_network) |c| gpa.free(c);
    }

    fn freeNet(gpa: std.mem.Allocator, n: *Net) void {
        gpa.free(n.path);
        gpa.free(n.name);
        gpa.free(n.device);
    }

    fn freeKnown(gpa: std.mem.Allocator, k: *Known) void {
        gpa.free(k.path);
        gpa.free(k.name);
    }

    /// Replace a string slot with a copy of `new`; OOM keeps the old value.
    fn replaceStr(self: *Model, slot: *[]u8, new: []const u8) void {
        const copy = self.gpa.dupe(u8, new) catch return;
        self.gpa.free(slot.*);
        slot.* = copy;
    }

    fn findDevice(self: *Model, path: []const u8) ?*Device {
        for (self.devices.items) |*d| {
            if (std.mem.eql(u8, d.path, path)) return d;
        }
        return null;
    }

    fn findNet(self: *Model, path: []const u8) ?*Net {
        for (self.nets.items) |*n| {
            if (std.mem.eql(u8, n.path, path)) return n;
        }
        return null;
    }

    fn findNetConst(self: *const Model, path: []const u8) ?*const Net {
        for (self.nets.items) |*n| {
            if (std.mem.eql(u8, n.path, path)) return n;
        }
        return null;
    }

    fn findKnown(self: *Model, path: []const u8) ?*Known {
        for (self.knowns.items) |*k| {
            if (std.mem.eql(u8, k.path, path)) return k;
        }
        return null;
    }

    fn ensureDevice(self: *Model, path: []const u8) ?*Device {
        if (self.findDevice(path)) |d| return d;
        const p = self.gpa.dupe(u8, path) catch return null;
        self.devices.append(self.gpa, .{ .path = p }) catch {
            self.gpa.free(p);
            return null;
        };
        return &self.devices.items[self.devices.items.len - 1];
    }

    fn ensureNet(self: *Model, path: []const u8) ?*Net {
        if (self.findNet(path)) |n| return n;
        const p = self.gpa.dupe(u8, path) catch return null;
        self.nets.append(self.gpa, .{ .path = p }) catch {
            self.gpa.free(p);
            return null;
        };
        return &self.nets.items[self.nets.items.len - 1];
    }

    fn ensureKnown(self: *Model, path: []const u8) ?*Known {
        if (self.findKnown(path)) |k| return k;
        const p = self.gpa.dupe(u8, path) catch return null;
        self.knowns.append(self.gpa, .{ .path = p }) catch {
            self.gpa.free(p);
            return null;
        };
        return &self.knowns.items[self.knowns.items.len - 1];
    }

    /// Ingest a whole ObjectManager tree (GetManagedObjects snapshot or a
    /// one-object InterfacesAdded parse). Effects are deliberately
    /// discarded: initial population is not an edge.
    fn ingestObjects(self: *Model, objects: []const bus_mod.ObjectEntry) void {
        for (objects) |*obj| {
            for (obj.interfaces) |*ip| {
                _ = self.applyInterface(obj.path, ip.name, ip.props, &.{});
            }
        }
    }

    /// Apply one interface's property set (from ingest or a
    /// PropertiesChanged batch) to the object at `path`.
    fn applyInterface(
        self: *Model,
        path: []const u8,
        iface_name: []const u8,
        changed: []const bus_mod.Prop,
        invalidated: []const [:0]const u8,
    ) ApplyResult {
        if (std.mem.eql(u8, iface_name, device_interface)) {
            const dev = self.ensureDevice(path) orelse return .{};
            for (changed) |p| {
                if (std.mem.eql(u8, p.name, "Name")) {
                    if (p.value == .s) self.replaceStr(&dev.name, p.value.s);
                } else if (std.mem.eql(u8, p.name, "Powered")) {
                    if (p.value == .b) dev.powered = p.value.b;
                } else if (std.mem.eql(u8, p.name, "Mode")) {
                    if (p.value == .s) dev.mode = parseMode(p.value.s);
                }
            }
            return .{};
        }
        if (std.mem.eql(u8, iface_name, station_interface)) {
            const dev = self.ensureDevice(path) orelse return .{};
            var res: ApplyResult = .{};
            dev.has_station = true;
            for (changed) |p| {
                if (std.mem.eql(u8, p.name, "State")) {
                    if (p.value == .s) {
                        if (!std.mem.eql(u8, dev.station_state, p.value.s))
                            res.station_state_changed = true;
                        self.replaceStr(&dev.station_state, p.value.s);
                    }
                } else if (std.mem.eql(u8, p.name, "Scanning")) {
                    if (p.value == .b) {
                        if (dev.scanning and !p.value.b) res.scan_finished = true;
                        dev.scanning = p.value.b;
                    }
                } else if (std.mem.eql(u8, p.name, "ConnectedNetwork")) {
                    if (p.value == .o) {
                        const copy = self.gpa.dupe(u8, p.value.o) catch continue;
                        if (dev.connected_network) |old| self.gpa.free(old);
                        dev.connected_network = copy;
                    }
                }
            }
            for (invalidated) |name| {
                if (std.mem.eql(u8, name, "ConnectedNetwork")) {
                    if (dev.connected_network) |old| self.gpa.free(old);
                    dev.connected_network = null;
                }
            }
            return res;
        }
        if (std.mem.eql(u8, iface_name, ap_interface)) {
            const dev = self.ensureDevice(path) orelse return .{};
            var res: ApplyResult = .{};
            dev.has_ap = true;
            for (changed) |p| {
                if (std.mem.eql(u8, p.name, "Started")) {
                    if (p.value == .b) {
                        if (dev.ap_started != p.value.b) res.ap_started_changed = true;
                        dev.ap_started = p.value.b;
                    }
                }
            }
            return res;
        }
        if (std.mem.eql(u8, iface_name, network_interface)) {
            const net = self.ensureNet(path) orelse return .{};
            for (changed) |p| {
                if (std.mem.eql(u8, p.name, "Name")) {
                    if (p.value == .s) self.replaceStr(&net.name, p.value.s);
                } else if (std.mem.eql(u8, p.name, "Type")) {
                    if (p.value == .s) net.security = securityFromType(p.value.s);
                } else if (std.mem.eql(u8, p.name, "Connected")) {
                    if (p.value == .b) net.connected = p.value.b;
                } else if (std.mem.eql(u8, p.name, "Device")) {
                    if (p.value == .o) self.replaceStr(&net.device, p.value.o);
                } else if (std.mem.eql(u8, p.name, "KnownNetwork")) {
                    if (p.value == .o) net.known = true;
                }
            }
            for (invalidated) |name| {
                if (std.mem.eql(u8, name, "KnownNetwork")) net.known = false;
            }
            return .{};
        }
        if (std.mem.eql(u8, iface_name, known_network_interface)) {
            const known = self.ensureKnown(path) orelse return .{};
            for (changed) |p| {
                if (std.mem.eql(u8, p.name, "Name")) {
                    if (p.value == .s) self.replaceStr(&known.name, p.value.s);
                } else if (std.mem.eql(u8, p.name, "Type")) {
                    if (p.value == .s) known.security = securityFromType(p.value.s);
                }
            }
            return .{};
        }
        return .{};
    }

    /// InterfacesRemoved: drop the tracked facet(s) of the object.
    fn removeInterfaces(self: *Model, path: []const u8, names: []const [:0]const u8) void {
        for (names) |name| {
            if (std.mem.eql(u8, name, device_interface)) {
                for (self.devices.items, 0..) |*d, i| {
                    if (std.mem.eql(u8, d.path, path)) {
                        var dead = self.devices.swapRemove(i);
                        freeDevice(self.gpa, &dead);
                        break;
                    }
                }
            } else if (std.mem.eql(u8, name, station_interface)) {
                if (self.findDevice(path)) |dev| {
                    dev.has_station = false;
                    dev.scanning = false;
                    self.gpa.free(dev.station_state);
                    dev.station_state = &.{};
                    if (dev.connected_network) |c| self.gpa.free(c);
                    dev.connected_network = null;
                }
            } else if (std.mem.eql(u8, name, ap_interface)) {
                if (self.findDevice(path)) |dev| {
                    dev.has_ap = false;
                    dev.ap_started = false;
                }
            } else if (std.mem.eql(u8, name, network_interface)) {
                for (self.nets.items, 0..) |*n, i| {
                    if (std.mem.eql(u8, n.path, path)) {
                        var dead = self.nets.swapRemove(i);
                        freeNet(self.gpa, &dead);
                        break;
                    }
                }
            } else if (std.mem.eql(u8, name, known_network_interface)) {
                for (self.knowns.items, 0..) |*k, i| {
                    if (std.mem.eql(u8, k.path, path)) {
                        var dead = self.knowns.swapRemove(i);
                        freeKnown(self.gpa, &dead);
                        break;
                    }
                }
            }
        }
    }
};

/// Deep-copy a NetworkInfo slice into `allocator` (the pre-AP scan
/// cache serves per-request copies; callers use a per-request arena).
fn copyNetworkInfos(
    allocator: std.mem.Allocator,
    items: []const NetworkInfo,
) error{OutOfMemory}![]NetworkInfo {
    const out = allocator.alloc(NetworkInfo, items.len) catch return error.OutOfMemory;
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |ni| allocator.free(ni.ssid);
        allocator.free(out);
    }
    for (items, 0..) |ni, i| {
        out[i] = ni;
        out[i].ssid = allocator.dupe(u8, ni.ssid) catch return error.OutOfMemory;
        n = i + 1;
    }
    return out;
}

fn freeNetworkInfos(gpa: std.mem.Allocator, items: []NetworkInfo) void {
    for (items) |ni| gpa.free(ni.ssid);
    gpa.free(items);
}

/// Build a State snapshot from the model (no rssi — that needs a bus
/// call and is layered on by Wifi.state). Strings referencing the model
/// are duped into `allocator`; static fallbacks ("unavailable",
/// "unknown") are literals — callers use a per-request arena and never
/// free fields individually.
/// The v1 DUT radio (docs/07 §4 single-radio policy, the same rule as
/// apRadioPathZ): the FIRST device alphabetically by interface name;
/// devices whose Name property has not arrived yet lose to any named
/// device, and when NO device is named the first mirrored device stands
/// in (single-radio boards in the instant before Name lands). EVERY
/// station-facing surface (state snapshot, stationPathZ and therefore
/// scan/networks/tryConnect, the rssi read) is scoped to this device —
/// NOT "the first device that has a Station interface": on multi-radio
/// rigs (the hwsim e2e) the helper radios' Station objects otherwise
/// masquerade as the DUT's. Found live in the phase-4 AP e2e: with
/// wlan0 in AP mode its Station object is gone, the model fell through
/// to wlan2 — the "phone" radio — so the phone's own association
/// attempt surfaced as network.wifi.state "connecting", the
/// provisioning machine took that for the portal flip starting and
/// bounced the AP (leaveAp/enterAp every ~5 s), which is exactly why
/// the phone's auth/handshake frames kept dying mid-air.
fn dutDevice(model: *const Model) ?*const Device {
    var best: ?*const Device = null;
    for (model.devices.items) |*d| {
        if (d.name.len == 0) continue;
        if (best == null or std.mem.order(u8, d.name, best.?.name) == .lt) best = d;
    }
    if (best == null and model.devices.items.len > 0) best = &model.devices.items[0];
    return best;
}

fn modelState(model: *const Model, allocator: std.mem.Allocator) error{OutOfMemory}!State {
    var st: State = .{
        .radio_present = false,
        .powered = false,
        .mode = .off,
        .connected_ssid = null,
        .rssi_dbm = null,
        .station_state = "unavailable",
    };
    const dev = dutDevice(model) orelse return st;
    st.radio_present = true;
    st.powered = dev.powered;
    st.mode = if (!dev.powered) .off else dev.mode;
    if (dev.has_station) {
        st.station_state = if (dev.station_state.len == 0)
            "unknown"
        else
            try allocator.dupe(u8, dev.station_state);
        if (dev.connected_network) |np| {
            if (model.findNetConst(np)) |n| {
                if (n.name.len > 0) st.connected_ssid = try allocator.dupe(u8, n.name);
            }
        }
    }
    return st;
}

// ---- the backend ------------------------------------------------------------

/// The wifi reconciler/backend. One instance, owned by main; HTTP
/// handlers call it through a module global (update.zig pattern).
pub const Wifi = struct {
    gpa: std.mem.Allocator,
    bus: *bus_mod.Bus,
    store: *store_mod.Store,
    registry: *ops.Registry,
    events: *events_mod.EventBus,
    /// Overridable for live tests; /data/net/iwd on real images.
    state_dir: []const u8 = iwd_state_dir,
    /// The AP-window netconfig override location (see ap_netconf_path);
    /// empty disables the swap (unit tests, boards without radios).
    netconf_override_path: []const u8 = ap_netconf_path,
    /// The baked iwd config (the CONFIGURATION_DIRECTORY fallback): when
    /// the EFFECTIVE config already enables netconfig, apStart skips the
    /// override+restart entirely — see netconfigAlreadyEnabled.
    baked_conf_path: []const u8 = iwd_baked_conf_path,

    /// Guards model + pending_scan + owned_conn. Leaf lock; see the
    /// file-header contract (never call Bus while holding it).
    mu: sync.Mutex = .{},
    model: Model,
    /// In-flight scan operation; id is the registry-owned slice from
    /// create() (valid until eviction — a running scan is never the
    /// eviction victim in practice, see ops.zig bounds).
    pending_scan: ?struct { id: []const u8 } = null,

    /// Store-connection strings this module installed into store.config.
    /// Replaced strings are RETIRED (kept until deinit) instead of freed:
    /// store getters hand out un-copied slices to concurrent readers
    /// (store.zig header), so freeing on replace would be a UAF. Tiny,
    /// rare allocations — bounded by the number of connection changes per
    /// daemon run. Followup: a real Store setter with copy-in semantics.
    owned_conn: ?struct { ssid: []u8, psk: []u8 } = null,
    retired: std.ArrayList([]u8) = .empty,

    /// AP identity installed by the last successful apStart (guarded by
    /// mu). The flip's ap_start_profile command re-uses it — the profile
    /// file is already on disk, StartProfile only needs the ssid.
    ap_ssid_buf: [32]u8 = undefined,
    ap_ssid_len: usize = 0,

    /// Pre-AP scan snapshot (docs/07 §4 edge case: scanning while the
    /// radio is an AP is chipset-limited, so the portal serves the last
    /// station-side scan taken just before the flip). gpa-owned
    /// NetworkInfo slice; mu-guarded.
    ap_scan_cache: ?[]NetworkInfo = null,

    match_added: ?*bus_mod.Match = null,
    match_removed: ?*bus_mod.Match = null,
    match_props: ?*bus_mod.Match = null,

    /// Install the InterfacesAdded/Removed + tree PropertiesChanged
    /// matches, snapshot the iwd tree (GetManagedObjects), and render the
    /// known-network file from the store. Everything iwd-facing is
    /// best-effort: with iwd down the model stays empty and fills in via
    /// InterfacesAdded when it appears (ObjectManager emits them for
    /// every object it registers).
    pub fn init(
        gpa: std.mem.Allocator,
        bus: *bus_mod.Bus,
        store: *store_mod.Store,
        registry: *ops.Registry,
        events: *events_mod.EventBus,
    ) Error!*Wifi {
        const self = gpa.create(Wifi) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .bus = bus,
            .store = store,
            .registry = registry,
            .events = events,
            .model = .{ .gpa = gpa },
        };

        // Matches BEFORE the snapshot so nothing is missed; ingest is
        // idempotent (ensure* dedupes by path) so overlap is harmless.
        self.match_added = bus.matchInterfacesAdded(iwd_service, iwd_manager_path, onInterfacesAdded, self) catch null;
        self.match_removed = bus.matchInterfacesRemoved(iwd_service, iwd_manager_path, onInterfacesRemoved, self) catch null;
        self.match_props = bus.matchPropertiesChangedTree(iwd_service, iwd_path_namespace, onPropertiesChanged, self) catch null;

        if (bus.getManagedObjects(gpa, iwd_service, iwd_manager_path)) |tree_const| {
            var tree = tree_const;
            defer tree.deinit();
            self.mu.lock();
            self.model.ingestObjects(tree.objects);
            self.mu.unlock();
        } else |err| {
            std.log.info("wifi: iwd tree snapshot unavailable ({s}); waiting for InterfacesAdded", .{@errorName(err)});
        }

        // Reconcile the persisted profile onto disk so iwd autoconnects
        // (iwd watches the state dir — knownnetworks.c:1130).
        if (store.getWifiConnection()) |conn| {
            writeProfile(gpa, self.state_dir, conn.ssid, conn.psk) catch |err| {
                std.log.warn("wifi: rendering stored profile failed: {s}", .{@errorName(err)});
            };
        }
        return self;
    }

    pub fn deinit(self: *Wifi) void {
        if (self.match_added) |m| m.cancel();
        if (self.match_removed) |m| m.cancel();
        if (self.match_props) |m| m.cancel();
        self.model.deinit();
        if (self.owned_conn) |oc| {
            self.gpa.free(oc.ssid);
            self.gpa.free(oc.psk);
        }
        for (self.retired.items) |s| self.gpa.free(s);
        self.retired.deinit(self.gpa);
        if (self.ap_scan_cache) |cache| freeNetworkInfos(self.gpa, cache);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    // -- public surface -------------------------------------------------------

    /// Trigger Station.Scan as a tracked operation (POST /network/wifi/scan
    /// → 202 {"operation": "/api/v1/operations/op-N"}); completion arrives
    /// via the Station "Scanning" true→false PropertiesChanged edge. A
    /// scan already in flight returns its existing operation id
    /// (idempotent re-POST). Returned id is registry-owned.
    pub fn scan(self: *Wifi) Error![]const u8 {
        var sbuf: [max_path_len]u8 = undefined;
        const sta = self.stationPathZ(&sbuf) orelse {
            // AP window (no Station interface): scanning is
            // chipset-limited, so the operation completes immediately
            // against the pre-AP snapshot — the portal's poll loop keeps
            // flowing (docs/07 §4 edge case).
            const have_cache = blk: {
                self.mu.lock();
                defer self.mu.unlock();
                break :blk self.ap_scan_cache != null;
            };
            if (!have_cache) return error.NoRadio;
            const id = self.registry.create(.wifi_scan) catch return error.OutOfMemory;
            self.registry.succeed(id, "scan complete (pre-AP cached results)");
            _ = self.events.publishEnvelope(event_wifi_scan_done, id, "{}") catch 0;
            return id;
        };
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.pending_scan) |p| return p.id;
        }
        const id = self.registry.create(.wifi_scan) catch return error.OutOfMemory;
        self.registry.update(id, .running, 0, "scanning");
        {
            self.mu.lock();
            defer self.mu.unlock();
            self.pending_scan = .{ .id = id };
        }
        var msg = self.bus.callMethod(iwd_service, sta, station_interface, "Scan", &.{}) catch |err| {
            // iwd answers net.connman.iwd.InProgress (dbus_error_busy)
            // when its OWN scan — autoconnect/periodic, common right
            // after the daemon starts — or a connect attempt is in
            // flight. That is not a failure of the scan contract: when
            // the radio is scanning, ride that scan's Scanning
            // true→false edge to completion like our own; otherwise
            // (connecting/roaming) complete immediately against current
            // results — iwd will not start a fresh scan until idle.
            if (std.mem.eql(u8, self.bus.lastDbusError(), "net.connman.iwd.InProgress")) {
                var scanning_now = false;
                {
                    self.mu.lock();
                    defer self.mu.unlock();
                    if (self.model.findDevice(sta)) |d| scanning_now = d.scanning;
                }
                if (!scanning_now) self.completePendingScan();
                return id;
            }
            self.mu.lock();
            self.pending_scan = null;
            self.mu.unlock();
            var detail_buf: [280]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "iwd Scan failed: {s}", .{self.bus.lastDbusError()}) catch "iwd Scan failed";
            self.registry.fail(id, detail);
            return switch (err) {
                error.Disconnected => error.BusUnavailable,
                else => error.IwdError,
            };
        };
        msg.deinit();
        return id;
    }

    /// Latest results — GET /network/wifi/networks. Primary source is
    /// Station.GetOrderedNetworks (PRESENT in the pinned iwd-3.12:
    /// src/station.c:5302, reply "a(on)" of network object path + signal
    /// in 0.01-dBm units); when that call fails (e.g. device flipped out
    /// of station mode) the mirrored Network objects are enumerated
    /// instead (signal unknown → 0). Strings are `allocator`-owned;
    /// callers use a per-request arena.
    pub fn networks(self: *Wifi, allocator: std.mem.Allocator) Error![]NetworkInfo {
        var sbuf: [max_path_len]u8 = undefined;
        const sta = self.stationPathZ(&sbuf) orelse {
            // AP window: the Station interface (and its Network objects)
            // are gone — serve the pre-AP snapshot so the portal's list
            // stays populated (docs/07 §4 edge case).
            self.mu.lock();
            defer self.mu.unlock();
            if (self.ap_scan_cache) |cache| return copyNetworkInfos(allocator, cache);
            return error.NoRadio;
        };
        var msg = self.bus.callMethod(iwd_service, sta, station_interface, "GetOrderedNetworks", &.{}) catch |err| switch (err) {
            error.Disconnected => return error.BusUnavailable,
            else => return self.networksFromModel(allocator),
        };
        defer msg.deinit();

        const Entry = struct { path: []u8, signal_dbm: i16 };
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |e| allocator.free(e.path);
            entries.deinit(allocator);
        }
        if (!(msg.enterContainer('a', "(on)") catch return error.IwdError)) return error.IwdError;
        while (msg.enterContainer('r', "on") catch return error.IwdError) {
            const p = msg.readObjectPath() catch return error.IwdError;
            var signal_dbm: i16 = 0;
            if (comptime @hasDecl(bus_mod.Message, "readI16")) {
                const mbm = msg.readI16() catch return error.IwdError;
                signal_dbm = @divTrunc(mbm, 100); // 0.01-dBm → dBm
            } else {
                // Until the bus.zig readI16 followup lands the value is
                // skipped; ORDER is still iwd's best-first ordering.
                msg.skip("n") catch return error.IwdError;
            }
            msg.exitContainer() catch return error.IwdError;
            const copy = allocator.dupe(u8, p) catch return error.OutOfMemory;
            entries.append(allocator, .{ .path = copy, .signal_dbm = signal_dbm }) catch {
                allocator.free(copy);
                return error.OutOfMemory;
            };
        }
        msg.exitContainer() catch return error.IwdError;

        var out: std.ArrayList(NetworkInfo) = .empty;
        errdefer {
            for (out.items) |ni| allocator.free(ni.ssid);
            out.deinit(allocator);
        }
        self.mu.lock();
        defer self.mu.unlock();
        for (entries.items) |e| {
            const n = self.model.findNet(e.path) orelse continue;
            const sec = n.security orelse continue; // WEP/unknown: filtered
            if (n.name.len == 0) continue;
            const ssid = allocator.dupe(u8, n.name) catch return error.OutOfMemory;
            out.append(allocator, .{
                .ssid = ssid,
                .signal_dbm = e.signal_dbm,
                .security = sec,
                .known = n.known,
                .connected = n.connected,
            }) catch {
                allocator.free(ssid);
                return error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(allocator) catch error.OutOfMemory;
    }

    /// Snapshot the current station-side scan into ap_scan_cache
    /// (best-effort — no station or no results keeps any older cache).
    fn cacheScanResults(self: *Wifi) void {
        const snapshot = self.networks(self.gpa) catch return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.ap_scan_cache) |old| freeNetworkInfos(self.gpa, old);
        self.ap_scan_cache = snapshot;
    }

    fn networksFromModel(self: *Wifi, allocator: std.mem.Allocator) Error![]NetworkInfo {
        self.mu.lock();
        defer self.mu.unlock();
        var out: std.ArrayList(NetworkInfo) = .empty;
        errdefer {
            for (out.items) |ni| allocator.free(ni.ssid);
            out.deinit(allocator);
        }
        for (self.model.nets.items) |*n| {
            const sec = n.security orelse continue;
            if (n.name.len == 0) continue;
            const ssid = allocator.dupe(u8, n.name) catch return error.OutOfMemory;
            out.append(allocator, .{
                .ssid = ssid,
                .signal_dbm = 0,
                .security = sec,
                .known = n.known,
                .connected = n.connected,
            }) catch {
                allocator.free(ssid);
                return error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(allocator) catch error.OutOfMemory;
    }

    /// PUT /network/wifi/connection: validate, persist {ssid, psk} to the
    /// store, render the known-network file, then best-effort connect the
    /// matching Network object (scan+retry-once when not visible).
    /// Valid-but-unsatisfiable configs are NOT API errors (docs/06 §7):
    /// once desired state is durable this returns success and the
    /// connection outcome flows via network.wifi.state events — iwd
    /// autoconnects later thanks to the rendered profile.
    pub fn connect(self: *Wifi, ssid: []const u8, psk: []const u8) Error!void {
        _ = try self.connectAttempt(ssid, psk);
    }

    /// connect() with an outcome: true iff the IMMEDIATE attempt settled
    /// successfully (Network.Connect replied without error). The desired
    /// state is durable either way — false is the AP flip's cue to bring
    /// the portal back (docs/07 §4 item 5), not an API error.
    pub fn connectAttempt(self: *Wifi, ssid: []const u8, psk: []const u8) Error!bool {
        if (ssid.len == 0 or ssid.len > 32) return error.InvalidArgument;
        try validatePsk(psk);

        self.persistConnection(ssid, psk) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StoreFailed => error.StoreFailed,
        };
        writeProfile(self.gpa, self.state_dir, ssid, psk) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArgument => error.InvalidArgument, // unreachable: validated above
            error.WriteFailed => error.StoreFailed,
        };
        return self.tryConnect(ssid, if (psk.len == 0) Security.open else .psk);
    }

    /// DELETE /network/wifi/connection: KnownNetwork.Forget (best-effort;
    /// iwd also removes its profile file itself), remove the rendered
    /// file(s), null the store field. Idempotent — no configured
    /// connection is a success.
    pub fn forget(self: *Wifi) Error!void {
        const conn = self.store.getWifiConnection() orelse return;
        const ssid = self.gpa.dupe(u8, conn.ssid) catch return error.OutOfMemory;
        defer self.gpa.free(ssid);

        var kbuf: [max_path_len]u8 = undefined;
        if (self.knownPathZ(&kbuf, ssid)) |kp| {
            if (self.bus.callMethod(iwd_service, kp, known_network_interface, "Forget", &.{})) |reply| {
                var m = reply;
                m.deinit();
            } else |err| {
                std.log.info("wifi: KnownNetwork.Forget failed: {s} ({s})", .{ @errorName(err), self.bus.lastDbusError() });
            }
        }
        removeProfiles(self.gpa, self.state_dir, ssid);
        self.clearConnection() catch return error.StoreFailed;
    }

    /// GET /network/wifi snapshot. Strings are `allocator`-owned or
    /// static literals — callers use a per-request arena. rssi_dbm comes
    /// from StationDiagnostic.GetDiagnostics ("RSSI", 'n', dBm —
    /// iwd-3.12 src/diagnostic.c:46) and is omitted when unavailable
    /// (not connected, old iwd, or the bus reader followup not applied).
    pub fn state(self: *Wifi, allocator: std.mem.Allocator) Error!State {
        var sbuf: [max_path_len]u8 = undefined;
        var sta: ?[:0]const u8 = null;
        var st: State = undefined;
        {
            self.mu.lock();
            defer self.mu.unlock();
            st = try modelState(&self.model, allocator);
            // rssi source: the DUT radio's own Station only (dutDevice
            // policy) — never a helper radio's.
            if (dutDevice(&self.model)) |d| {
                if (d.has_station)
                    sta = std.fmt.bufPrintZ(&sbuf, "{s}", .{d.path}) catch null;
            }
        }
        if (st.connected_ssid != null) {
            if (sta) |p| st.rssi_dbm = self.readRssi(p);
        }
        return st;
    }

    // -- internals ------------------------------------------------------------

    fn stationPathZ(self: *Wifi, buf: []u8) ?[:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        // DUT radio only (dutDevice policy): when OUR radio is in AP
        // mode this returns null even though helper radios on a test
        // rig still expose Station — the AP-window cache paths key off
        // exactly that null.
        const d = dutDevice(&self.model) orelse return null;
        if (!d.has_station) return null;
        return std.fmt.bufPrintZ(buf, "{s}", .{d.path}) catch null;
    }

    fn findNetworkPathZ(self: *Wifi, buf: []u8, ssid: []const u8, sec: Security) ?[:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.model.nets.items) |*n| {
            if (!std.mem.eql(u8, n.name, ssid)) continue;
            const nsec = n.security orelse continue;
            if (nsec != sec) continue;
            return std.fmt.bufPrintZ(buf, "{s}", .{n.path}) catch null;
        }
        return null;
    }

    fn knownPathZ(self: *Wifi, buf: []u8, ssid: []const u8) ?[:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.model.knowns.items) |*k| {
            if (std.mem.eql(u8, k.name, ssid))
                return std.fmt.bufPrintZ(buf, "{s}", .{k.path}) catch null;
        }
        return null;
    }

    /// The v1 AP radio: the FIRST iwd device alphabetically by interface
    /// name (wlan0 on every current board — module-header radio policy).
    /// Unlike stationPathZ this must work when the Station interface is
    /// gone (mid-flip the device only has Device/AccessPoint facets).
    fn apRadioPathZ(self: *Wifi, buf: []u8) ?[:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const dev = dutDevice(&self.model) orelse return null;
        return std.fmt.bufPrintZ(buf, "{s}", .{dev.path}) catch null;
    }

    /// True while OUR AP radio reports AccessPoint.Started (mirrored
    /// from PropertiesChanged — GET /network/wifi/ap's `enabled`
    /// source). Scoped to the v1 AP radio (first device alphabetically,
    /// the apRadioPathZ policy) — NOT "any AP in the iwd tree": the
    /// hwsim e2e rig runs its upstream test AP on wlan1 through the
    /// same iwd, and counting it made `enabled` true before cragd ever
    /// touched a radio (caught live by the provisioning-e2e case).
    pub fn apActive(self: *Wifi) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var best: ?*const Device = null;
        for (self.model.devices.items) |*d| {
            if (d.name.len == 0) continue;
            if (best == null or std.mem.order(u8, d.name, best.?.name) == .lt) best = d;
        }
        const dev = best orelse return false;
        return dev.has_ap and dev.ap_started;
    }

    /// True when the config iwd is RUNNING with already enables
    /// netconfig: first main.conf along the CONFIGURATION_DIRECTORY
    /// order (override, then the baked /etc/iwd/main.conf) wins —
    /// mirror of iwd-3.12 main.c:548-567 first-match loading.
    fn netconfigAlreadyEnabled(self: *Wifi) bool {
        var buf: [4096]u8 = undefined;
        const paths = [_][]const u8{ self.netconf_override_path, self.baked_conf_path };
        for (paths) |p| {
            if (p.len == 0) continue;
            const text = fsutil.readFileBounded(p, &buf) catch continue;
            return mainConfNetconfigEnabled(text);
        }
        return false;
    }

    /// Validate + persist {ssid, psk} (store + rendered iwd profile)
    /// WITHOUT any connect attempt: the AP-surface PUT persists before
    /// the 202 goes out, then the deferred AP→station flip owns the
    /// radio work (main.zig DeferredAction.wifi_flip).
    pub fn persistOnly(self: *Wifi, ssid: []const u8, psk: []const u8) Error!void {
        if (ssid.len == 0 or ssid.len > 32) return error.InvalidArgument;
        try validatePsk(psk);
        self.persistConnection(ssid, psk) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StoreFailed => error.StoreFailed,
        };
        writeProfile(self.gpa, self.state_dir, ssid, psk) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArgument => error.InvalidArgument, // unreachable: validated above
            error.WriteFailed => error.StoreFailed,
        };
    }

    /// Bounded wait for the radio Device object to (re)appear after an
    /// iwd restart (InterfacesAdded repopulates the model; the paths are
    /// stable /net/connman/iwd/<phy>/<ifindex> so dedupe is safe).
    fn waitForRadio(self: *Wifi) void {
        var buf: [max_path_len]u8 = undefined;
        var waited: u64 = 0;
        while (waited < ap_radio_wait_ms) : (waited += 200) {
            if (self.apRadioPathZ(&buf) != null) return;
            sync.sleepMs(200);
        }
        std.log.warn("wifi: radio did not reappear within {d} ms of the iwd restart", .{ap_radio_wait_ms});
    }

    /// org.freedesktop.DBus.Properties.Set on Device.Mode ("s" —
    /// writable, iwd-3.12 src/device.c:266; values "station"/"ap"/
    /// "ad-hoc", setting the current iftype completes immediately). Uses
    /// sd_bus_set_property directly under bus.mu — the same discipline
    /// as Bus.callMethod (all sd-bus access serialized by mu, eventfd
    /// kicked after) because Bus has no property-SET wrapper yet
    /// (followup: hoist as Bus.setPropertyString).
    fn setDeviceMode(self: *Wifi, path: [:0]const u8, mode: [:0]const u8) Error!void {
        const c = bus_mod.c;
        const b = self.bus;
        b.mu.lock();
        defer b.mu.unlock();
        defer {
            const one: u64 = 1; // Bus.kick(): wake the loop for fresh timeouts
            _ = linux.write(b.wake_fd, @ptrCast(&one), 8);
        }
        var err: c.sd_bus_error = .{ .name = null, .message = null, ._need_free = 0 };
        defer c.sd_bus_error_free(&err);
        const r = c.sd_bus_set_property(
            b.bus,
            iwd_service,
            path.ptr,
            device_interface,
            "Mode",
            &err,
            "s",
            mode.ptr,
        );
        if (r < 0) {
            const name: []const u8 = if (err.name) |n| std.mem.span(@as([*:0]const u8, @ptrCast(n))) else "(errno)";
            std.log.warn("wifi: Device.Mode={s} on {s} failed: {s} ({d})", .{ mode, path, name, r });
            return switch (-r) {
                @intFromEnum(linux.E.NOTCONN), @intFromEnum(linux.E.CONNRESET) => error.BusUnavailable,
                else => error.IwdError,
            };
        }
    }

    /// Install (ssid, psk) as the store's desired connection and persist.
    /// The previous owned strings are retired, not freed (see owned_conn).
    fn persistConnection(self: *Wifi, ssid: []const u8, psk: []const u8) error{ OutOfMemory, StoreFailed }!void {
        const s = self.gpa.dupe(u8, ssid) catch return error.OutOfMemory;
        const p = self.gpa.dupe(u8, psk) catch {
            self.gpa.free(s);
            return error.OutOfMemory;
        };
        self.store.beginMutate();
        self.store.config.network.wifi.connection = .{ .ssid = s, .psk = p };
        const res = self.store.persistLocked();
        self.store.endMutate();
        self.retireOwned();
        self.mu.lock();
        self.owned_conn = .{ .ssid = s, .psk = p };
        self.mu.unlock();
        res catch return error.StoreFailed;
    }

    fn clearConnection(self: *Wifi) error{StoreFailed}!void {
        self.store.beginMutate();
        self.store.config.network.wifi.connection = null;
        const res = self.store.persistLocked();
        self.store.endMutate();
        self.retireOwned();
        res catch return error.StoreFailed;
    }

    fn retireOwned(self: *Wifi) void {
        self.mu.lock();
        const oc = self.owned_conn orelse {
            self.mu.unlock();
            return;
        };
        self.owned_conn = null;
        // OOM here would lose track of a few bytes; deliberate (freeing
        // would risk a UAF for a concurrent store reader).
        self.retired.append(self.gpa, oc.ssid) catch {};
        self.retired.append(self.gpa, oc.psk) catch {};
        self.mu.unlock();
    }

    /// Best-effort immediate connect: find the Network object for `ssid`,
    /// scanning + retrying once when it is not visible yet. Failures are
    /// degraded, never errors — the profile on disk makes iwd autoconnect
    /// when the network appears. Returns true iff the immediate attempt
    /// settled successfully (the AP flip's success signal).
    fn tryConnect(self: *Wifi, ssid: []const u8, sec: Security) bool {
        var pbuf: [max_path_len]u8 = undefined;
        if (self.findNetworkPathZ(&pbuf, ssid, sec)) |path| return self.connectNetworkPath(path);

        var sbuf: [max_path_len]u8 = undefined;
        // AP→station flip race (seen live on the fast x86_64 board):
        // right after Device.Mode="station" the Station interface's
        // InterfacesAdded can lag this call, and bailing out here loses
        // the immediate attempt (iwd autoconnect is the fallback, but
        // the e2e budget wants the direct path). Wait briefly for the
        // interface to register before concluding there is no station.
        const sta = blk: {
            var waited: u64 = 0;
            while (waited < station_register_wait_ms) : (waited += 150) {
                if (self.stationPathZ(&sbuf)) |s| break :blk s;
                sync.sleepMs(150);
            }
            break :blk self.stationPathZ(&sbuf) orelse return false;
        };
        if (self.bus.callMethod(iwd_service, sta, station_interface, "Scan", &.{})) |reply| {
            var m = reply;
            m.deinit();
        } else |_| {} // Busy (already scanning) etc: the poll below still works

        var waited: u64 = 0;
        while (waited < connect_scan_wait_ms) : (waited += 150) {
            sync.sleepMs(150);
            if (self.findNetworkPathZ(&pbuf, ssid, sec)) |path| return self.connectNetworkPath(path);
        }
        std.log.info("wifi: ssid not visible after scan; profile installed, iwd autoconnects when it appears", .{});
        return false;
    }

    fn connectNetworkPath(self: *Wifi, path: [:0]const u8) bool {
        // Network.Connect ("" args — iwd-3.12 src/network.c:2165) replies
        // only once the attempt settles; sd_bus_call waits (default
        // timeout) with bus.mu held, which delays signal dispatch a few
        // seconds worst-case. Accepted for v1 (single caller, rare op).
        if (self.bus.callMethod(iwd_service, path, network_interface, "Connect", &.{})) |reply| {
            var m = reply;
            m.deinit();
            return true;
        } else |err| {
            std.log.warn("wifi: Network.Connect failed: {s} ({s})", .{ @errorName(err), self.bus.lastDbusError() });
            return false;
        }
    }

    fn readRssi(self: *Wifi, station_path: [:0]const u8) ?i16 {
        // Needs bus.zig's a{sv} reader made public (followup: `pub fn
        // readPropArray`); until then rssi is simply omitted.
        if (comptime @hasDecl(bus_mod.Message, "readPropArray")) {
            var msg = self.bus.callMethod(iwd_service, station_path, station_diagnostic_interface, "GetDiagnostics", &.{}) catch return null;
            defer msg.deinit();
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const props = msg.readPropArray(arena.allocator()) catch return null;
            for (props) |p| {
                if (std.mem.eql(u8, p.name, "RSSI")) {
                    switch (p.value) {
                        .n => |v| return v, // already plain dBm
                        else => {},
                    }
                }
            }
            return null;
        } else {
            return null;
        }
    }

    /// Bus-thread post-processing of a Scanning true→false edge.
    fn completePendingScan(self: *Wifi) void {
        self.mu.lock();
        const maybe = self.pending_scan;
        self.pending_scan = null;
        self.mu.unlock();
        const p = maybe orelse return;
        self.registry.succeed(p.id, "scan complete");
        _ = self.events.publishEnvelope(event_wifi_scan_done, p.id, "{}") catch 0;
    }

    /// Publish a network.wifi.state event from the current model.
    fn publishStateEvent(self: *Wifi) void {
        var state_buf: [64]u8 = undefined;
        var ssid_buf: [32]u8 = undefined;
        var station_state: []const u8 = "unavailable";
        var ssid: ?[]const u8 = null;
        {
            self.mu.lock();
            defer self.mu.unlock();
            // DUT radio only (dutDevice policy) — this event feeds the
            // provisioning machine's wifi_connect_* mapping, and a
            // helper radio's "connecting" here IS the AP-bounce bug the
            // dutDevice doc block describes (second copy found live:
            // the phone's Network.Connect still bounced the AP once
            // after the snapshot paths were scoped).
            if (dutDevice(&self.model)) |d| {
                if (d.has_station) {
                    const s = if (d.station_state.len == 0) "unknown" else d.station_state;
                    const n = @min(s.len, state_buf.len);
                    @memcpy(state_buf[0..n], s[0..n]);
                    station_state = state_buf[0..n];
                    if (d.connected_network) |np| {
                        if (self.model.findNet(np)) |net| {
                            if (net.name.len > 0 and net.name.len <= ssid_buf.len) {
                                @memcpy(ssid_buf[0..net.name.len], net.name);
                                ssid = ssid_buf[0..net.name.len];
                            }
                        }
                    }
                }
            }
        }
        const payload = std.json.Stringify.valueAlloc(self.gpa, .{
            .state = station_state,
            .connected_ssid = ssid,
        }, .{}) catch return;
        defer self.gpa.free(payload);
        _ = self.events.publishEnvelope(event_wifi_state, null, payload) catch 0;
    }
};

// ---- bus-thread signal callbacks --------------------------------------------
// Contract (bus.zig): they run on the bus thread with the bus mutex HELD.
// Quick work only; self.mu / ops.Registry / EventBus are leaf locks and
// safe; calling back into the Bus is forbidden.

fn onInterfacesAdded(ctx: ?*anyopaque, msg: *bus_mod.Message) void {
    const self: *Wifi = @ptrCast(@alignCast(ctx.?));
    var tree = msg.readInterfacesAdded(self.gpa) catch return;
    defer tree.deinit();
    self.mu.lock();
    self.model.ingestObjects(tree.objects);
    self.mu.unlock();
}

fn onInterfacesRemoved(ctx: ?*anyopaque, msg: *bus_mod.Message) void {
    const self: *Wifi = @ptrCast(@alignCast(ctx.?));
    var removed = msg.readInterfacesRemoved(self.gpa) catch return;
    defer removed.deinit();
    self.mu.lock();
    self.model.removeInterfaces(removed.path, removed.interfaces);
    self.mu.unlock();
}

fn onPropertiesChanged(ctx: ?*anyopaque, msg: *bus_mod.Message) void {
    const self: *Wifi = @ptrCast(@alignCast(ctx.?));
    const path = msg.path() orelse return;
    var update = msg.readPropertiesChanged(self.gpa) catch return;
    defer update.deinit();
    self.mu.lock();
    const res = self.model.applyInterface(path, update.interface, update.changed, update.invalidated);
    self.mu.unlock();
    if (res.scan_finished) self.completePendingScan();
    if (res.station_state_changed) {
        // Only the DUT radio's Station narrates network.wifi.state —
        // helper radios on a multi-radio rig must neither bounce the
        // provisioning machine nor spam SSE with unchanged snapshots.
        const is_dut = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            const d = dutDevice(&self.model) orelse break :blk false;
            break :blk std.mem.eql(u8, d.path, path);
        };
        if (is_dut) self.publishStateEvent();
    }
    // AP lifecycle observation (AccessPoint.Started edge): logged here;
    // the provisioning machine polls apActive() from its own context
    // (bus-thread callbacks must stay quick and bus-free).
    if (res.ap_started_changed) std.log.info("wifi: AccessPoint.Started changed (path {s})", .{path});
}

/// Module global set by main once the backend is constructed (update.zig
/// discipline); handlers answer 501/503 while null.
pub var global: ?*Wifi = null;

// ---- AP-mode extension points (M3 phase-4 spine; signatures + identity) -----
//
// Mechanics VERIFIED against iwd-3.12 src/ap.c (the pinned tarball):
//   - net.connman.iwd.AccessPoint methods (ap.c:4716): Start(ssid,
//     wpa2_passphrase), Stop(), StartProfile(ssid), Scan(),
//     GetOrderedNetworks().
//   - StartProfile(ssid) loads <STATE_DIRECTORY>/ap/<ssid>.ap
//     (ap.c:4437 storage_get_path("ap/%s.ap")). The profile carries
//     [Security].Passphrase (≤63 chars, ap.c:3486) and the [IPv4] pool
//     block — Address, Netmask, Gateway, IPRange, DNSList, LeaseTime
//     (ap.c:3366..3454) — which drives iwd's BUILT-IN DHCP server.
//   - TRAP (confirmed live in the phase-3 suite, MIGRATION-NOTES §18):
//     the [IPv4] block is honored only when netconfig_enabled()
//     (ap.c:3364), i.e. global main.conf EnableNetworkConfiguration=true.
//     The shipped AD-015 posture is =false (station addressing belongs
//     to dhcpcd), so the FILL must flip that setting for AP mode —
//     per-mode config swap around the AP window, not a permanent change.
//
// The fill therefore uses StartProfile (Start(ssid,psk) cannot carry the
// DHCP pool): cragd renders /data/net/iwd/ap/<ssid>.ap (the ap/ dir is
// tmpfiles-created cragd-owned) and calls StartProfile on the AP
// radio's Device path after switching Device.Mode to "ap".
//
// v1 radio policy (baked): cragd's OWN radio is the FIRST iwd device
// alphabetically by interface name (wlan0 on every current board). A
// multi-radio product that wants a dedicated AP radio gets a store knob
// later — additive.

/// Where rendered AP profiles live (iwd StartProfile contract above).
pub const ap_profile_dir = iwd_state_dir ++ "/ap";
/// HMAC label for the deterministic AP PSK (versioned: a future scheme
/// change bumps the label, never silently changes existing labels).
pub const ap_psk_label = "crag-ap-psk-v1";
/// The AP provisioning subnet (docs/07 §4; portal.zig mirrors it).
pub const ap_address = "192.168.223.1";
pub const ap_netmask = "255.255.255.0";

/// SSID "crag-<last 6 hex of machine-id>" — identical derivation to the
/// mDNS instance label so the device presents one identity everywhere.
pub fn deriveApSsid(buf: *[32]u8, machine_id: []const u8) []const u8 {
    return @import("mdns.zig").instanceLabel(buf, machine_id);
}

/// Deterministic per-device WPA2 passphrase (baked decision):
/// hex(hmac-sha256(key = machine-id, msg = "crag-ap-psk-v1"))[0..16].
/// 16 lowercase-hex chars — a valid 8..63-char WPA passphrase, printable
/// on the device label; cragctl exposes it via a socket-surface-only
/// endpoint (fill work) for the label-printing station.
pub fn deriveApPsk(out: *[16]u8, machine_id: []const u8) []const u8 {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    const key = std.mem.trim(u8, machine_id, " \t\r\n");
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, ap_psk_label, key);
    var hex: [2 * HmacSha256.mac_length]u8 = undefined;
    for (mac, 0..) |b, i| {
        const digits = "0123456789abcdef";
        hex[2 * i] = digits[b >> 4];
        hex[2 * i + 1] = digits[b & 0xf];
    }
    @memcpy(out, hex[0..16]);
    return out;
}

/// Render the iwd AP profile document (pure; writeApProfile installs it
/// as ap_profile_dir/<ssid>.ap before StartProfile). Pool: cragd at .1,
/// clients .10-.199, DNS pointed at the portal catch-all (docs/07 §4).
pub fn renderApProfile(allocator: std.mem.Allocator, psk: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator,
        \\# Rendered by cragd (docs/07 SS4 AP provisioning) - do not edit.
        \\[Security]
        \\Passphrase={s}
        \\
        \\[IPv4]
        \\Address={s}
        \\Netmask={s}
        \\IPRange=192.168.223.10,192.168.223.199
        \\DNSList={s}
        \\LeaseTime=300
        \\
    , .{ psk, ap_address, ap_netmask, ap_address });
}

/// Render + atomically install the AP profile as
/// <state_dir>/ap/<ssid>.ap (0600, tmp+rename). The filename uses the
/// ssid VERBATIM — StartProfile loads storage_get_path("ap/%s.ap", ssid)
/// with NO hex encoding (iwd-3.12 src/ap.c:4437), unlike station
/// profiles. Derived SSIDs ("crag-" + 6 hex) are always safe; foreign
/// ssids are rejected unless filename-clean (defensive: '/' or '.' in an
/// ssid must never escape the ap/ directory).
pub fn writeApProfile(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    ssid: []const u8,
    psk: []const u8,
) error{ OutOfMemory, InvalidArgument, WriteFailed }!void {
    if (ssid.len == 0 or ssid.len > 32) return error.InvalidArgument;
    for (ssid) |b| {
        if (!(std.ascii.isAlphanumeric(b) or b == '-' or b == '_')) return error.InvalidArgument;
    }
    // AP profiles REQUIRE a passphrase ([Security].Passphrase, ≤63 chars
    // — ap.c:3486/3517); open provisioning APs are not a thing here.
    if (psk.len < 8 or psk.len > 63) return error.InvalidArgument;
    const content = try renderApProfile(allocator, psk);
    defer allocator.free(content);

    const dir = std.fmt.allocPrint(allocator, "{s}/ap", .{state_dir}) catch return error.OutOfMemory;
    defer allocator.free(dir);
    mkdirAll(dir, 0o700);
    const path = std.fmt.allocPrint(allocator, "{s}/{s}.ap", .{ dir, ssid }) catch return error.OutOfMemory;
    defer allocator.free(path);
    const tmp = std.fmt.allocPrint(allocator, "{s}.tmp", .{path}) catch return error.OutOfMemory;
    defer allocator.free(tmp);
    try writeFileMode(tmp, content, 0o600);
    fsutil.rename(tmp, path) catch return error.WriteFailed;
}

// -- the iwd netconfig window (TRAP, module header + MIGRATION-NOTES §18) ----
//
// iwd honors an AP profile's [IPv4] DHCP pool only when the GLOBAL
// main.conf sets EnableNetworkConfiguration=true (netconfig_enabled,
// ap.c:3364) — and main.conf is read ONCE at startup, first match along
// $CONFIGURATION_DIRECTORY (iwd-3.12 src/main.c:548-567, ':'-separated).
// The shipped AD-015 posture is =false (dhcpcd owns station addressing).
// For the AP window cragd renders the override below into ap_netconf_dir
// — which the iwd shadow dinit service lists FIRST in
// CONFIGURATION_DIRECTORY (/etc/crag/iwd.env followup) — and restarts
// iwd around install/remove. tmpfiles creates ap_netconf_dir
// cragd-owned; /run contents vanish on reboot, so a crash mid-window
// can never leave the split-brain config permanent.

/// The baked iwd main.conf (AD-015 posture: EnableNetworkConfiguration=
/// false on shipped images). Second entry of the CONFIGURATION_DIRECTORY
/// list in the iwd shadow service env (boards/common iwd.env).
pub const iwd_baked_conf_path = "/etc/iwd/main.conf";

/// Minimal main.conf scan for EnableNetworkConfiguration (iwd parses it
/// with l_settings — a flat KEY=VALUE ini; the [General] group is the
/// only place iwd reads this key, and crag configs never repeat it).
/// Used to decide whether the AP netconfig window needs opening at all:
/// the hwsim e2e rig bind-mounts a =true config over /etc/iwd, and
/// restarting iwd there would kill the upstream test AP on wlan1.
pub fn mainConfNetconfigEnabled(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "EnableNetworkConfiguration=")) {
            const v = line["EnableNetworkConfiguration=".len..];
            return std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "true");
        }
    }
    return false;
}

pub const ap_netconf_dir = "/run/crag/iwd";
pub const ap_netconf_path = ap_netconf_dir ++ "/main.conf";
pub const ap_netconf_conf =
    "# AP-window override rendered by cragd (docs/07 SS4) - do not edit.\n" ++
    "# Present ONLY while the provisioning AP is up: iwd's AP DHCP server\n" ++
    "# needs EnableNetworkConfiguration=true; station addressing stays\n" ++
    "# with dhcpcd (AD-015) because no station connect runs in AP mode.\n" ++
    "[General]\n" ++
    "EnableNetworkConfiguration=true\n";

/// How long apStart waits for the radio Device object after an iwd
/// restart (the netconfig window swap) before giving up.
const ap_radio_wait_ms: u64 = 10_000;

/// Restart iwd through the dinit client so it re-reads main.conf.
/// Gated on the dinit.zig restart addition (followup): until it lands
/// the swap is logged as inactive and the AP comes up WITHOUT the DHCP
/// pool (portal reachable only via static client config — degraded).
fn restartIwd() bool {
    const dinit = @import("dinit.zig");
    if (comptime @hasDecl(dinit, "restartServiceByName")) {
        dinit.restartServiceByName(dinit.default_socket_path, "iwd") catch |err| {
            std.log.warn("wifi: iwd restart for the netconfig window failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    } else {
        std.log.warn("wifi: dinit restart support missing — netconfig window swap inactive, AP DHCP pool disabled", .{});
        return false;
    }
}

/// Flip the v1 AP radio (first iwd device alphabetically by name — the
/// module-header radio policy) into AP mode and start the rendered
/// profile: write <ssid>.ap → open the netconfig window (override +
/// iwd restart) → Device.Mode="ap" → AccessPoint.StartProfile(ssid).
/// StartProfile replies only once the AP is up (ap.c pends the message
/// until the START event), so success here means the AP is beaconing.
/// AlreadyExists (AP already started) is success.
pub fn apStart(self: *Wifi, ssid: []const u8, psk: []const u8) Error!void {
    writeApProfile(self.gpa, self.state_dir, ssid, psk) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArgument => error.InvalidArgument,
        error.WriteFailed => error.StoreFailed,
    };

    // docs/07 §4 edge case: snapshot the station-side scan BEFORE the
    // flip — the portal serves it while the radio is busy being an AP.
    self.cacheScanResults();

    // Netconfig window: best-effort — a failed swap degrades the AP
    // (no DHCP pool) instead of blocking the portal entirely. Skipped
    // entirely when the EFFECTIVE config (first main.conf along the
    // CONFIGURATION_DIRECTORY list) already enables netconfig: nothing
    // to swap, and the restart would needlessly bounce running iwd
    // state (on the hwsim e2e rig it would kill the upstream test AP).
    if (self.netconf_override_path.len > 0 and !self.netconfigAlreadyEnabled()) {
        if (std.fs.path.dirname(self.netconf_override_path)) |dir| mkdirAll(dir, 0o755);
        if (fsutil.writeFileSync(self.netconf_override_path, ap_netconf_conf)) {
            if (restartIwd()) self.waitForRadio();
        } else |err| {
            std.log.warn("wifi: netconfig override write failed: {s} (AP DHCP pool disabled)", .{@errorName(err)});
        }
    }

    var rbuf: [max_path_len]u8 = undefined;
    const radio = self.apRadioPathZ(&rbuf) orelse return error.NoRadio;
    try self.setDeviceMode(radio, "ap");

    var zbuf: [33]u8 = undefined;
    const ssid_z = std.fmt.bufPrintZ(&zbuf, "{s}", .{ssid}) catch return error.InvalidArgument;

    // The AccessPoint interface is registered when the iftype flips; the
    // Properties.Set reply and the InterfacesAdded signal can race, so
    // retry briefly on UnknownObject/UnknownInterface-shaped failures.
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        if (self.bus.callMethod(iwd_service, radio, ap_interface, "StartProfile", &.{.{ .s = ssid_z }})) |reply| {
            var m = reply;
            m.deinit();
            break;
        } else |err| {
            const name = self.bus.lastDbusError();
            if (std.mem.endsWith(u8, name, ".AlreadyExists")) break; // idempotent re-entry
            if (err != error.Disconnected and attempt < 10) {
                sync.sleepMs(200);
                continue;
            }
            std.log.warn("wifi: AccessPoint.StartProfile({s}) failed: {s} ({s})", .{ ssid, @errorName(err), name });
            // Best-effort: do not leave the radio dead in ap mode with
            // no AP running — the station path still works then.
            self.setDeviceMode(radio, "station") catch {};
            return if (err == error.Disconnected) error.BusUnavailable else error.IwdError;
        }
    }

    self.mu.lock();
    @memcpy(self.ap_ssid_buf[0..ssid.len], ssid);
    self.ap_ssid_len = ssid.len;
    self.mu.unlock();
}

/// AccessPoint.Stop() + Device.Mode="station" — the AP→station half of
/// the single-radio flip — then close the netconfig window (remove the
/// override + restart iwd back onto /etc/iwd/main.conf, restoring the
/// AD-015 posture). Idempotent: no radio is a no-op; Stop failures
/// (never started, already stopped) are tolerated; the mode set
/// completes immediately when the iftype already matches (iwd-3.12
/// src/device.c:233); a missing override file skips the restart.
pub fn apStop(self: *Wifi) Error!void {
    var rbuf: [max_path_len]u8 = undefined;
    if (self.apRadioPathZ(&rbuf)) |radio| {
        if (self.bus.callMethod(iwd_service, radio, ap_interface, "Stop", &.{})) |reply| {
            var m = reply;
            m.deinit();
        } else |err| {
            std.log.info("wifi: AccessPoint.Stop: {s} ({s}) — tolerated", .{ @errorName(err), self.bus.lastDbusError() });
        }
        try self.setDeviceMode(radio, "station");
    }
    if (self.netconf_override_path.len > 0 and fsutil.pathExists(self.netconf_override_path)) {
        fsutil.unlink(self.netconf_override_path) catch |err| {
            std.log.warn("wifi: netconfig override removal failed: {s}", .{@errorName(err)});
        };
        if (restartIwd()) self.waitForRadio();
    }
}

// ---- the AP→station flip (docs/07 §4 items 4–5) -----------------------------
//
// PURE sequence logic, mirroring provision.zig's step/Machine split so the
// wrong-password loop is unit-testable without a bus: Flip yields typed
// commands, the executor reports each command's outcome, and the table
// decides what comes next. The REAL executor (flipToStation) maps commands
// onto iwd calls; tests script outcomes through a fake.

pub const FlipCmd = enum {
    /// AccessPoint.Stop (failure tolerated: "not started" is fine).
    ap_stop,
    /// Device.Mode="station".
    set_mode_station,
    /// The existing station connect path (scan-wait + Network.Connect);
    /// ok == the attempt settled successfully.
    connect_station,
    /// Device.Mode="ap" (failure path: bring the portal back).
    set_mode_ap,
    /// AccessPoint.StartProfile with the last apStart identity.
    ap_start_profile,
};

pub const FlipStatus = enum { running, station_connected, ap_restored, failed };

pub const Flip = struct {
    stage: Stage = .stop_ap,

    pub const Stage = enum {
        stop_ap,
        to_station,
        connect,
        restore_mode,
        restart_ap,
        done_station,
        done_restored,
        dead,
    };

    /// The command to execute now; null when the flip is finished.
    pub fn command(self: Flip) ?FlipCmd {
        return switch (self.stage) {
            .stop_ap => .ap_stop,
            .to_station => .set_mode_station,
            .connect => .connect_station,
            .restore_mode => .set_mode_ap,
            .restart_ap => .ap_start_profile,
            .done_station, .done_restored, .dead => null,
        };
    }

    /// Feed the outcome of the current command.
    pub fn advance(self: *Flip, ok: bool) void {
        self.stage = switch (self.stage) {
            // Stop failing means "was not started" — station is next
            // either way.
            .stop_ap => .to_station,
            .to_station => if (ok) Stage.connect else .restore_mode,
            // The wrong-password loop (docs/07 §4 item 5): a failed
            // attempt restores the AP so the portal can re-offer the form.
            .connect => if (ok) Stage.done_station else .restore_mode,
            .restore_mode => if (ok) Stage.restart_ap else .dead,
            .restart_ap => if (ok) Stage.done_restored else .dead,
            .done_station, .done_restored, .dead => self.stage,
        };
    }

    pub fn status(self: Flip) FlipStatus {
        return switch (self.stage) {
            .done_station => .station_connected,
            .done_restored => .ap_restored,
            .dead => .failed,
            else => .running,
        };
    }
};

/// Command executor: ctx + fn, provision.Effects style. Returns whether
/// the command succeeded.
pub const FlipExecutor = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, cmd: FlipCmd) bool,
};

/// Drive a Flip to completion against `exec`. Pure control flow — the
/// scripted-fake tests below pin the full sequence table.
pub fn runFlip(exec: FlipExecutor) FlipStatus {
    var f: Flip = .{};
    while (f.command()) |cmd| f.advance(exec.run(exec.ctx, cmd));
    return f.status();
}

/// The real AP→station flip: persist {ssid, psk} (durable BEFORE any
/// radio surgery — a power cut mid-flip must leave the desired state on
/// disk), then Stop → Mode="station" → existing connect path; on failure
/// Mode="ap" + StartProfile brings the portal back (.ap_restored).
/// Callers (the provisioning machine / ApController) translate the
/// status into wifi_connect_failed/succeeded events; .failed means the
/// radio could not even be restored (log + next observe retries).
pub fn flipToStation(self: *Wifi, ssid: []const u8, psk: []const u8) Error!FlipStatus {
    if (ssid.len == 0 or ssid.len > 32) return error.InvalidArgument;
    try validatePsk(psk);

    // Desired state on disk FIRST: a power cut mid-flip must reboot into
    // "profile present, iwd autoconnects", never into a half-flip.
    self.persistConnection(ssid, psk) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StoreFailed => error.StoreFailed,
    };
    writeProfile(self.gpa, self.state_dir, ssid, psk) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArgument => error.InvalidArgument, // unreachable: validated above
        error.WriteFailed => error.StoreFailed,
    };

    const Real = struct {
        wifi: *Wifi,
        ssid: []const u8,
        psk: []const u8,

        fn run(ctx: ?*anyopaque, cmd: FlipCmd) bool {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            const w = r.wifi;
            switch (cmd) {
                .ap_stop => {
                    var rbuf: [max_path_len]u8 = undefined;
                    const radio = w.apRadioPathZ(&rbuf) orelse return true; // nothing to stop
                    if (w.bus.callMethod(iwd_service, radio, ap_interface, "Stop", &.{})) |reply| {
                        var m = reply;
                        m.deinit();
                    } else |_| {} // tolerated (see Flip.advance)
                    return true;
                },
                .set_mode_station, .set_mode_ap => {
                    var rbuf: [max_path_len]u8 = undefined;
                    const radio = w.apRadioPathZ(&rbuf) orelse return false;
                    const mode: [:0]const u8 = if (cmd == .set_mode_ap) "ap" else "station";
                    w.setDeviceMode(radio, mode) catch return false;
                    return true;
                },
                .connect_station => {
                    // Persist already happened above; this is mechanism only.
                    const sec: Security = if (r.psk.len == 0) .open else .psk;
                    return w.tryConnect(r.ssid, sec);
                },
                .ap_start_profile => {
                    var sbuf: [32]u8 = undefined;
                    w.mu.lock();
                    const n = w.ap_ssid_len;
                    @memcpy(sbuf[0..n], w.ap_ssid_buf[0..n]);
                    w.mu.unlock();
                    if (n == 0) return false; // no prior apStart — nothing to restore
                    var zbuf: [33]u8 = undefined;
                    const ssid_z = std.fmt.bufPrintZ(&zbuf, "{s}", .{sbuf[0..n]}) catch return false;
                    var rbuf: [max_path_len]u8 = undefined;
                    const radio = w.apRadioPathZ(&rbuf) orelse return false;
                    if (w.bus.callMethod(iwd_service, radio, ap_interface, "StartProfile", &.{.{ .s = ssid_z }})) |reply| {
                        var m = reply;
                        m.deinit();
                        return true;
                    } else |_| {
                        return std.mem.endsWith(u8, w.bus.lastDbusError(), ".AlreadyExists");
                    }
                },
            }
        }
    };

    var real: Real = .{ .wifi = self, .ssid = ssid, .psk = psk };
    const status = runFlip(.{ .ctx = &real, .run = Real.run });
    if (status == .failed)
        std.log.warn("wifi: AP flip failed AND the AP could not be restored (radio dead until next observe)", .{});
    return status;
}

// ---- tests ------------------------------------------------------------------

test "module global starts null (handlers answer 501/503)" {
    try std.testing.expect(global == null);
}

test "ssid filename encoding matches iwd storage.c (plain and hex forms)" {
    const a = std.testing.allocator;

    // Alnum + "-_ " pass through verbatim (storage.c:284 isalnum/strchr).
    const plain = try ssidFileName(a, "MyHome-Net_2 4", .psk);
    defer a.free(plain);
    try std.testing.expectEqualStrings("MyHome-Net_2 4.psk", plain);

    // '.' forces hex encoding.
    const dotted = try ssidFileName(a, "crag.lan", .psk);
    defer a.free(dotted);
    try std.testing.expectEqualStrings("=637261672e6c616e.psk", dotted);

    // Non-ASCII (UTF-8 bytes) force hex encoding, lowercase digits
    // (ell/util.c:474 l_util_hexstring).
    const utf8 = try ssidFileName(a, "café", .psk);
    defer a.free(utf8);
    try std.testing.expectEqualStrings("=636166c3a9.psk", utf8);

    const cjk = try ssidFileName(a, "日本", .psk);
    defer a.free(cjk);
    try std.testing.expectEqualStrings("=e697a5e69cac.psk", cjk);

    // Extension follows security_to_str (common.c:35).
    const open = try ssidFileName(a, "guest", .open);
    defer a.free(open);
    try std.testing.expectEqualStrings("guest.open", open);

    const eap = try ssidFileName(a, "corp", .@"8021x");
    defer a.free(eap);
    try std.testing.expectEqualStrings("corp.8021x", eap);
}

test "profile rendering: passphrase preferred, raw 64-hex psk, open, invalid shapes" {
    const a = std.testing.allocator;

    const pass = try renderProfile(a, "hunter22-secret");
    defer a.free(pass);
    try std.testing.expectEqualStrings("[Security]\nPassphrase=hunter22-secret\n", pass);

    const raw_hex = "6dd4e232b16ea2c9d10a10e0c9f9d9e8" ++ "6dd4e232b16ea2c9d10a10e0c9f9d9e8";
    const raw = try renderProfile(a, raw_hex);
    defer a.free(raw);
    try std.testing.expectEqualStrings("[Security]\nPreSharedKey=" ++ raw_hex ++ "\n", raw);

    const open = try renderProfile(a, "");
    defer a.free(open);
    try std.testing.expectEqualStrings("[Settings]\nAutoConnect=true\n", open);

    // Too short, too long (64 non-hex), control bytes: rejected.
    try std.testing.expectError(error.InvalidArgument, renderProfile(a, "short7c"));
    try std.testing.expectError(error.InvalidArgument, renderProfile(a, "z" ** 64));
    try std.testing.expectError(error.InvalidArgument, renderProfile(a, "line\nbreak-pass"));
}

test "writeProfile/removeProfiles: atomic install into the state dir, 0600" {
    const a = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const dir = fsutil.testTmpPath(&dir_buf, "iwd-state");

    try writeProfile(a, dir, "crag-test", "hunter22-secret");
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/crag-test.psk", .{dir});
    const back = try fsutil.readFileAlloc(a, path, 4096);
    defer a.free(back);
    try std.testing.expectEqualStrings("[Security]\nPassphrase=hunter22-secret\n", back);

    // No tmp litter.
    var tmp_buf: [170]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    try std.testing.expect(!fsutil.pathExists(tmp));

    // Secret files are 0600.
    const path_z = try posix.toPosixPath(path);
    var stx: linux.Statx = undefined;
    try std.testing.expect(linux.errno(linux.statx(linux.AT.FDCWD, &path_z, 0, .{ .MODE = true }, &stx)) == .SUCCESS);
    try std.testing.expectEqual(@as(u16, 0o600), stx.mode & 0o7777);

    // Hex-named variant and removal of both security flavors.
    try writeProfile(a, dir, "crag.lan", "");
    var open_buf: [200]u8 = undefined;
    const open_path = try std.fmt.bufPrint(&open_buf, "{s}/=637261672e6c616e.open", .{dir});
    try std.testing.expect(fsutil.pathExists(open_path));

    removeProfiles(a, dir, "crag-test");
    removeProfiles(a, dir, "crag.lan");
    try std.testing.expect(!fsutil.pathExists(path));
    try std.testing.expect(!fsutil.pathExists(open_path));

    try std.testing.expectError(error.InvalidArgument, writeProfile(a, dir, "", "hunter22"));
}

// Model fixtures: ObjectEntry slices shaped exactly like bus.zig's
// readManagedObjects output (the Message→tree parsing itself is covered
// by bus.zig's socketpair tests against iwd's wire shapes).

const t_dev_path = "/net/connman/iwd/0/3";
const t_net_path = "/net/connman/iwd/0/3/637261672d74657374_psk";
const t_known_path = "/net/connman/iwd/637261672d74657374_psk";

fn testIngest(model: *Model) void {
    var dev_props = [_]bus_mod.Prop{
        .{ .name = "Name", .value = .{ .s = "wlan0" } },
        .{ .name = "Powered", .value = .{ .b = true } },
        .{ .name = "Mode", .value = .{ .s = "station" } },
    };
    var sta_props = [_]bus_mod.Prop{
        .{ .name = "State", .value = .{ .s = "disconnected" } },
        .{ .name = "Scanning", .value = .{ .b = false } },
    };
    var dev_ifaces = [_]bus_mod.InterfaceProps{
        .{ .name = device_interface, .props = &dev_props },
        .{ .name = station_interface, .props = &sta_props },
    };
    var net_props = [_]bus_mod.Prop{
        .{ .name = "Name", .value = .{ .s = "crag-test" } },
        .{ .name = "Type", .value = .{ .s = "psk" } },
        .{ .name = "Connected", .value = .{ .b = false } },
        .{ .name = "Device", .value = .{ .o = t_dev_path } },
        .{ .name = "KnownNetwork", .value = .{ .o = t_known_path } },
    };
    var net_ifaces = [_]bus_mod.InterfaceProps{
        .{ .name = network_interface, .props = &net_props },
    };
    var wep_props = [_]bus_mod.Prop{
        .{ .name = "Name", .value = .{ .s = "legacy" } },
        .{ .name = "Type", .value = .{ .s = "wep" } },
    };
    var wep_ifaces = [_]bus_mod.InterfaceProps{
        .{ .name = network_interface, .props = &wep_props },
    };
    var known_props = [_]bus_mod.Prop{
        .{ .name = "Name", .value = .{ .s = "crag-test" } },
        .{ .name = "Type", .value = .{ .s = "psk" } },
    };
    var known_ifaces = [_]bus_mod.InterfaceProps{
        .{ .name = known_network_interface, .props = &known_props },
    };
    const objects = [_]bus_mod.ObjectEntry{
        .{ .path = t_dev_path, .interfaces = &dev_ifaces },
        .{ .path = t_net_path, .interfaces = &net_ifaces },
        .{ .path = "/net/connman/iwd/0/3/6c6567616379_wep", .interfaces = &wep_ifaces },
        .{ .path = t_known_path, .interfaces = &known_ifaces },
    };
    model.ingestObjects(&objects);
}

test "model: ObjectManager tree ingest maps devices/stations/networks/knowns" {
    var model: Model = .{ .gpa = std.testing.allocator };
    defer model.deinit();
    testIngest(&model);

    const dev = model.findDevice(t_dev_path).?;
    try std.testing.expectEqualStrings("wlan0", dev.name);
    try std.testing.expect(dev.powered);
    try std.testing.expectEqual(Mode.station, dev.mode);
    try std.testing.expect(dev.has_station);
    try std.testing.expectEqualStrings("disconnected", dev.station_state);
    try std.testing.expect(!dev.scanning);
    try std.testing.expect(dev.connected_network == null);

    const net = model.findNet(t_net_path).?;
    try std.testing.expectEqualStrings("crag-test", net.name);
    try std.testing.expectEqual(@as(?Security, .psk), net.security);
    try std.testing.expect(net.known);
    try std.testing.expect(!net.connected);
    try std.testing.expectEqualStrings(t_dev_path, net.device);

    // WEP maps to null security (unsupported by iwd, filtered from lists).
    try std.testing.expect(model.findNet("/net/connman/iwd/0/3/6c6567616379_wep").?.security == null);

    const known = model.findKnown(t_known_path).?;
    try std.testing.expectEqualStrings("crag-test", known.name);

    // Re-ingest is idempotent (no duplicate objects).
    testIngest(&model);
    try std.testing.expectEqual(@as(usize, 1), model.devices.items.len);
    try std.testing.expectEqual(@as(usize, 2), model.nets.items.len);
    try std.testing.expectEqual(@as(usize, 1), model.knowns.items.len);
}

test "model: PropertiesChanged effects — state edge, scanning edge, invalidation" {
    var model: Model = .{ .gpa = std.testing.allocator };
    defer model.deinit();
    testIngest(&model);

    // Station.State disconnected → connecting: state-changed effect.
    var connecting = [_]bus_mod.Prop{
        .{ .name = "State", .value = .{ .s = "connecting" } },
    };
    var res = model.applyInterface(t_dev_path, station_interface, &connecting, &.{});
    try std.testing.expect(res.station_state_changed);
    try std.testing.expect(!res.scan_finished);
    try std.testing.expectEqualStrings("connecting", model.findDevice(t_dev_path).?.station_state);

    // Same value again: no edge.
    res = model.applyInterface(t_dev_path, station_interface, &connecting, &.{});
    try std.testing.expect(!res.station_state_changed);

    // Connected: State + ConnectedNetwork in one batch; Network flips too.
    var connected = [_]bus_mod.Prop{
        .{ .name = "State", .value = .{ .s = "connected" } },
        .{ .name = "ConnectedNetwork", .value = .{ .o = t_net_path } },
    };
    res = model.applyInterface(t_dev_path, station_interface, &connected, &.{});
    try std.testing.expect(res.station_state_changed);
    var net_connected = [_]bus_mod.Prop{
        .{ .name = "Connected", .value = .{ .b = true } },
    };
    _ = model.applyInterface(t_net_path, network_interface, &net_connected, &.{});
    try std.testing.expect(model.findNet(t_net_path).?.connected);
    try std.testing.expectEqualStrings(t_net_path, model.findDevice(t_dev_path).?.connected_network.?);

    // Scanning true then false: the completion edge fires exactly once.
    var scanning_on = [_]bus_mod.Prop{.{ .name = "Scanning", .value = .{ .b = true } }};
    res = model.applyInterface(t_dev_path, station_interface, &scanning_on, &.{});
    try std.testing.expect(!res.scan_finished);
    var scanning_off = [_]bus_mod.Prop{.{ .name = "Scanning", .value = .{ .b = false } }};
    res = model.applyInterface(t_dev_path, station_interface, &scanning_off, &.{});
    try std.testing.expect(res.scan_finished);
    res = model.applyInterface(t_dev_path, station_interface, &scanning_off, &.{});
    try std.testing.expect(!res.scan_finished);

    // Disconnect: ConnectedNetwork arrives INVALIDATED (ell emits it in
    // the `as` tail), KnownNetwork invalidation un-knows the network.
    var disc = [_]bus_mod.Prop{.{ .name = "State", .value = .{ .s = "disconnected" } }};
    const inval_conn = [_][:0]const u8{"ConnectedNetwork"};
    res = model.applyInterface(t_dev_path, station_interface, &disc, &inval_conn);
    try std.testing.expect(res.station_state_changed);
    try std.testing.expect(model.findDevice(t_dev_path).?.connected_network == null);
    const inval_known = [_][:0]const u8{"KnownNetwork"};
    _ = model.applyInterface(t_net_path, network_interface, &.{}, &inval_known);
    try std.testing.expect(!model.findNet(t_net_path).?.known);
}

test "model: InterfacesRemoved drops facets and whole objects" {
    var model: Model = .{ .gpa = std.testing.allocator };
    defer model.deinit();
    testIngest(&model);

    // Station removal (e.g. mode switch to AP) keeps the Device.
    const rm_station = [_][:0]const u8{station_interface};
    model.removeInterfaces(t_dev_path, &rm_station);
    const dev = model.findDevice(t_dev_path).?;
    try std.testing.expect(!dev.has_station);
    try std.testing.expectEqualStrings("", dev.station_state);

    const rm_net = [_][:0]const u8{network_interface};
    model.removeInterfaces(t_net_path, &rm_net);
    try std.testing.expect(model.findNet(t_net_path) == null);

    const rm_known = [_][:0]const u8{known_network_interface};
    model.removeInterfaces(t_known_path, &rm_known);
    try std.testing.expect(model.findKnown(t_known_path) == null);

    const rm_dev = [_][:0]const u8{device_interface};
    model.removeInterfaces(t_dev_path, &rm_dev);
    try std.testing.expect(model.findDevice(t_dev_path) == null);
}

test "model: State snapshot mapping (radio, mode, connected ssid)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{ .gpa = std.testing.allocator };
    defer model.deinit();

    // No radio at all.
    var st = try modelState(&model, arena);
    try std.testing.expect(!st.radio_present);
    try std.testing.expectEqual(Mode.off, st.mode);
    try std.testing.expectEqualStrings("unavailable", st.station_state);
    try std.testing.expect(st.connected_ssid == null);

    testIngest(&model);
    st = try modelState(&model, arena);
    try std.testing.expect(st.radio_present);
    try std.testing.expect(st.powered);
    try std.testing.expectEqual(Mode.station, st.mode);
    try std.testing.expectEqualStrings("disconnected", st.station_state);
    try std.testing.expect(st.connected_ssid == null);
    try std.testing.expect(st.rssi_dbm == null);

    // Connect, then verify ssid resolution through the network object.
    var connected = [_]bus_mod.Prop{
        .{ .name = "State", .value = .{ .s = "connected" } },
        .{ .name = "ConnectedNetwork", .value = .{ .o = t_net_path } },
    };
    _ = model.applyInterface(t_dev_path, station_interface, &connected, &.{});
    st = try modelState(&model, arena);
    try std.testing.expectEqualStrings("connected", st.station_state);
    try std.testing.expectEqualStrings("crag-test", st.connected_ssid.?);

    // Powered off: mode reads off even though iftype says station.
    var off = [_]bus_mod.Prop{.{ .name = "Powered", .value = .{ .b = false } }};
    _ = model.applyInterface(t_dev_path, device_interface, &off, &.{});
    st = try modelState(&model, arena);
    try std.testing.expectEqual(Mode.off, st.mode);
    try std.testing.expect(!st.powered);
}

test "model: DUT scoping — a helper radio's Station never masquerades as ours" {
    // The phase-4 AP e2e regression (see dutDevice): wlan0 (the DUT, in
    // AP mode, Station gone) + wlan2 (the rig's "phone", Station busy
    // connecting). The state snapshot must narrate the DUT — mode ap,
    // station unavailable — NOT the phone's connect attempt, or the
    // provisioning machine mistakes the phone for the portal flip and
    // bounces the AP mid-handshake.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{ .gpa = std.testing.allocator };
    defer model.deinit();

    const dut_path = "/net/connman/iwd/0/13";
    const phone_path = "/net/connman/iwd/2/11";
    var dut_props = [_]bus_mod.Prop{
        .{ .name = "Name", .value = .{ .s = "wlan0" } },
        .{ .name = "Powered", .value = .{ .b = true } },
        .{ .name = "Mode", .value = .{ .s = "ap" } },
    };
    var dut_ifaces = [_]bus_mod.InterfaceProps{
        .{ .name = device_interface, .props = &dut_props },
    };
    var phone_props = [_]bus_mod.Prop{
        .{ .name = "Name", .value = .{ .s = "wlan2" } },
        .{ .name = "Powered", .value = .{ .b = true } },
        .{ .name = "Mode", .value = .{ .s = "station" } },
    };
    var phone_sta = [_]bus_mod.Prop{
        .{ .name = "State", .value = .{ .s = "connecting" } },
        .{ .name = "Scanning", .value = .{ .b = false } },
    };
    var phone_ifaces = [_]bus_mod.InterfaceProps{
        .{ .name = device_interface, .props = &phone_props },
        .{ .name = station_interface, .props = &phone_sta },
    };
    // Deliberately ingest the phone FIRST: order of appearance must not
    // beat the alphabetical DUT policy.
    const objects = [_]bus_mod.ObjectEntry{
        .{ .path = phone_path, .interfaces = &phone_ifaces },
        .{ .path = dut_path, .interfaces = &dut_ifaces },
    };
    model.ingestObjects(&objects);

    try std.testing.expectEqualStrings("wlan0", dutDevice(&model).?.name);
    const st = try modelState(&model, arena);
    try std.testing.expect(st.radio_present);
    try std.testing.expectEqual(Mode.ap, st.mode);
    try std.testing.expectEqualStrings("unavailable", st.station_state);
    try std.testing.expect(st.connected_ssid == null);

    // Nameless-model fallback: before any Name property lands the first
    // mirrored device stands in (single-radio boot instant).
    var bare: Model = .{ .gpa = std.testing.allocator };
    defer bare.deinit();
    var bare_props = [_]bus_mod.Prop{
        .{ .name = "Powered", .value = .{ .b = true } },
        .{ .name = "Mode", .value = .{ .s = "station" } },
    };
    var bare_ifaces = [_]bus_mod.InterfaceProps{
        .{ .name = device_interface, .props = &bare_props },
    };
    const bare_objects = [_]bus_mod.ObjectEntry{
        .{ .path = dut_path, .interfaces = &bare_ifaces },
    };
    bare.ingestObjects(&bare_objects);
    try std.testing.expectEqualStrings(dut_path, dutDevice(&bare).?.path);
}

test "live iwd backend (manual: CRAG_LIVE_IWD=1 against a real bus + iwd)" {
    if (std.c.getenv("CRAG_LIVE_IWD") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var st = try store_mod.Store.load(gpa, "/tmp/crag-live-iwd.json");
    defer st.deinit();
    var reg = ops.Registry.init(gpa);
    defer reg.deinit();
    var evb = events_mod.EventBus.init(gpa);
    defer evb.deinit();
    const bus = try bus_mod.Bus.connectSystem(gpa);
    defer bus.deinit();
    try bus.start();

    const w = try Wifi.init(gpa, bus, &st, &reg, &evb);
    defer w.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const snapshot = try w.state(arena_state.allocator());
    std.debug.print("wifi: radio={} powered={} mode={s} state={s}\n", .{
        snapshot.radio_present, snapshot.powered, @tagName(snapshot.mode), snapshot.station_state,
    });
}

test "AP identity: SSID from machine-id, deterministic 16-hex PSK" {
    var ssid_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "crag-9f03a1",
        deriveApSsid(&ssid_buf, "e5c1770f8ffb4dc7a276869f9f03a1\n"),
    );

    var psk_buf: [16]u8 = undefined;
    const psk = deriveApPsk(&psk_buf, "e5c1770f8ffb4dc7a276869f9f03a1\n");
    try std.testing.expectEqual(@as(usize, 16), psk.len);
    for (psk) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    // Deterministic: same id (modulo trailing whitespace) → same PSK.
    var psk_buf2: [16]u8 = undefined;
    const psk2 = deriveApPsk(&psk_buf2, "e5c1770f8ffb4dc7a276869f9f03a1");
    try std.testing.expectEqualStrings(psk, psk2);
    // Different device → different PSK.
    var psk_buf3: [16]u8 = undefined;
    const psk3 = deriveApPsk(&psk_buf3, "00000000000000000000000000000000");
    try std.testing.expect(!std.mem.eql(u8, psk, psk3));
    // Valid WPA passphrase by the daemon's own validator.
    try validatePsk(psk);
}

test "renderApProfile carries the StartProfile contract keys" {
    const a = std.testing.allocator;
    const doc = try renderApProfile(a, "0123456789abcdef");
    defer a.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "[Security]\nPassphrase=0123456789abcdef\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "[IPv4]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "Address=192.168.223.1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "Netmask=255.255.255.0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "IPRange=192.168.223.10,192.168.223.199\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "DNSList=192.168.223.1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "LeaseTime=300\n") != null);
}

test "AP PSK derivation: pinned vectors (versioned label crag-ap-psk-v1)" {
    // hex(hmac-sha256(key=machine-id, msg="crag-ap-psk-v1"))[0..16],
    // cross-checked against python hmac/hashlib. A change here means the
    // derivation drifted — devices already labeled in the field would
    // stop matching their printed passphrase. Bump ap_psk_label instead.
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings(
        "f5cd05c4d98ba678",
        deriveApPsk(&buf, "e5c1770f8ffb4dc7a276869f9f03a1"),
    );
    try std.testing.expectEqualStrings(
        "04f6ea736c802100",
        deriveApPsk(&buf, "0123456789abcdef0123456789abcdef\n"),
    );
}

test "writeApProfile: verbatim ap/<ssid>.ap install, 0600, hostile ssids rejected" {
    const a = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const dir = fsutil.testTmpPath(&dir_buf, "iwd-ap-state");
    try std.testing.expectEqualStrings("/data/net/iwd/ap", ap_profile_dir);

    try writeApProfile(a, dir, "crag-9f03a1", "68790122e723996d");
    var path_buf: [180]u8 = undefined;
    // Filename is the ssid VERBATIM + ".ap" (ap.c:4437) — no hex encoding.
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ap/crag-9f03a1.ap", .{dir});
    const back = try fsutil.readFileAlloc(a, path, 4096);
    defer a.free(back);
    try std.testing.expect(std.mem.indexOf(u8, back, "Passphrase=68790122e723996d\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, back, "[IPv4]\n") != null);

    // Secrets are 0600, tmp+rename leaves no litter.
    const path_z = try posix.toPosixPath(path);
    var stx: linux.Statx = undefined;
    try std.testing.expect(linux.errno(linux.statx(linux.AT.FDCWD, &path_z, 0, .{ .MODE = true }, &stx)) == .SUCCESS);
    try std.testing.expectEqual(@as(u16, 0o600), stx.mode & 0o7777);
    var tmp_buf: [190]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    try std.testing.expect(!fsutil.pathExists(tmp));
    fsutil.unlink(path) catch {};

    // StartProfile interpolates the ssid into a PATH — anything that is
    // not filename-clean must be rejected, and AP profiles require a
    // real WPA passphrase (ap.c:3486/3517).
    try std.testing.expectError(error.InvalidArgument, writeApProfile(a, dir, "../escape", "hunter22-secret"));
    try std.testing.expectError(error.InvalidArgument, writeApProfile(a, dir, "dot.dot", "hunter22-secret"));
    try std.testing.expectError(error.InvalidArgument, writeApProfile(a, dir, "sp ace", "hunter22-secret"));
    try std.testing.expectError(error.InvalidArgument, writeApProfile(a, dir, "crag-9f03a1", "short7c"));
    try std.testing.expectError(error.InvalidArgument, writeApProfile(a, dir, "crag-9f03a1", ""));
}

test "pre-AP scan cache: deep copy round-trip (per-request copies of the snapshot)" {
    const a = std.testing.allocator;
    const src = [_]NetworkInfo{
        .{ .ssid = "home-net", .signal_dbm = -48, .security = .psk, .known = true, .connected = false },
        .{ .ssid = "guest", .signal_dbm = -71, .security = .open, .known = false, .connected = false },
    };
    const copy = try copyNetworkInfos(a, &src);
    try std.testing.expectEqual(@as(usize, 2), copy.len);
    try std.testing.expectEqualStrings("home-net", copy[0].ssid);
    try std.testing.expect(copy[0].ssid.ptr != src[0].ssid.ptr); // deep, not aliased
    try std.testing.expectEqual(@as(i16, -71), copy[1].signal_dbm);
    try std.testing.expectEqual(Security.open, copy[1].security);
    freeNetworkInfos(a, copy);
}

test "AP netconfig window: override paths + content pin the iwd contract" {
    // /run/crag/iwd must be listed FIRST in the iwd shadow service's
    // CONFIGURATION_DIRECTORY (main.c:548-567 takes the first main.conf
    // found) — /etc/crag/iwd.env carries that (overlay).
    try std.testing.expectEqualStrings("/run/crag/iwd/main.conf", ap_netconf_path);
    try std.testing.expect(std.mem.startsWith(u8, ap_netconf_path, ap_netconf_dir));
    // The override flips exactly the one setting netconfig_enabled()
    // reads (netconfig.c:760-767) and nothing else.
    try std.testing.expect(std.mem.indexOf(u8, ap_netconf_conf, "[General]\nEnableNetworkConfiguration=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ap_netconf_conf, "=false") == null);
}

test "mainConfNetconfigEnabled: effective-config scan (window-skip decision)" {
    // The shipped AD-015 posture (window must OPEN).
    try std.testing.expect(!mainConfNetconfigEnabled("[General]\nEnableNetworkConfiguration=false\n"));
    // The e2e rig's bind-mounted override (window must be SKIPPED — a
    // restart would kill the upstream test AP on wlan1).
    try std.testing.expect(mainConfNetconfigEnabled("[General]\nEnableNetworkConfiguration=true\n"));
    // Our own rendered override document.
    try std.testing.expect(mainConfNetconfigEnabled(ap_netconf_conf));
    // Absent key / empty / comment-only: netconfig defaults off.
    try std.testing.expect(!mainConfNetconfigEnabled(""));
    try std.testing.expect(!mainConfNetconfigEnabled("[General]\n# EnableNetworkConfiguration=true\n"));
    try std.testing.expect(!mainConfNetconfigEnabled("[General]\nEnableNetworkConfiguration=1\n"));
    // Whitespace around the value tolerated (l_settings trims it).
    try std.testing.expect(mainConfNetconfigEnabled("EnableNetworkConfiguration= true \n"));
}

test "model: AccessPoint interface tracking (Started edge, removal, apActive mapping)" {
    var model: Model = .{ .gpa = std.testing.allocator };
    defer model.deinit();
    testIngest(&model);

    // Mode flip: Station removed, AccessPoint added (iwd re-registers
    // interfaces on the same Device path when the iftype changes).
    const rm_station = [_][:0]const u8{station_interface};
    model.removeInterfaces(t_dev_path, &rm_station);
    var ap_props = [_]bus_mod.Prop{
        .{ .name = "Started", .value = .{ .b = false } },
        .{ .name = "Name", .value = .{ .s = "crag-9f03a1" } },
    };
    var res = model.applyInterface(t_dev_path, ap_interface, &ap_props, &.{});
    try std.testing.expect(!res.ap_started_changed); // false → false: no edge
    const dev = model.findDevice(t_dev_path).?;
    try std.testing.expect(dev.has_ap);
    try std.testing.expect(!dev.ap_started);

    // Started true: the up edge fires exactly once.
    var started = [_]bus_mod.Prop{.{ .name = "Started", .value = .{ .b = true } }};
    res = model.applyInterface(t_dev_path, ap_interface, &started, &.{});
    try std.testing.expect(res.ap_started_changed);
    try std.testing.expect(dev.ap_started);
    res = model.applyInterface(t_dev_path, ap_interface, &started, &.{});
    try std.testing.expect(!res.ap_started_changed);

    // Interface removal (flip back to station) clears both flags.
    const rm_ap = [_][:0]const u8{ap_interface};
    model.removeInterfaces(t_dev_path, &rm_ap);
    try std.testing.expect(!dev.has_ap);
    try std.testing.expect(!dev.ap_started);
}

test "Flip: pure sequence table — happy path, wrong-password loop, dead ends" {
    const Script = struct {
        results: []const bool,
        i: usize = 0,
        log: [8]FlipCmd = undefined,
        n: usize = 0,

        fn run(ctx: ?*anyopaque, cmd: FlipCmd) bool {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.log[s.n] = cmd;
            s.n += 1;
            const ok = s.results[s.i];
            s.i += 1;
            return ok;
        }

        fn exec(s: *@This()) FlipExecutor {
            return .{ .ctx = s, .run = @This().run };
        }
    };

    // Happy path: Stop → Mode=station → connect ok.
    var happy: Script = .{ .results = &.{ true, true, true } };
    try std.testing.expectEqual(FlipStatus.station_connected, runFlip(happy.exec()));
    try std.testing.expectEqualSlices(
        FlipCmd,
        &.{ .ap_stop, .set_mode_station, .connect_station },
        happy.log[0..happy.n],
    );

    // Wrong password: connect fails → Mode=ap → StartProfile → restored
    // (the portal re-offers the form; docs/07 §4 item 5).
    var wrong: Script = .{ .results = &.{ true, true, false, true, true } };
    try std.testing.expectEqual(FlipStatus.ap_restored, runFlip(wrong.exec()));
    try std.testing.expectEqualSlices(
        FlipCmd,
        &.{ .ap_stop, .set_mode_station, .connect_station, .set_mode_ap, .ap_start_profile },
        wrong.log[0..wrong.n],
    );

    // AccessPoint.Stop failing ("not started") is tolerated — the flip
    // proceeds to station.
    var stop_fail: Script = .{ .results = &.{ false, true, true } };
    try std.testing.expectEqual(FlipStatus.station_connected, runFlip(stop_fail.exec()));

    // Mode=station failing skips the doomed connect and restores the AP.
    var mode_fail: Script = .{ .results = &.{ true, false, true, true } };
    try std.testing.expectEqual(FlipStatus.ap_restored, runFlip(mode_fail.exec()));
    try std.testing.expectEqualSlices(
        FlipCmd,
        &.{ .ap_stop, .set_mode_station, .set_mode_ap, .ap_start_profile },
        mode_fail.log[0..mode_fail.n],
    );

    // Restore failing at either step is a dead radio: .failed (caller
    // logs; the next provisioning observe retries enterAp).
    var dead1: Script = .{ .results = &.{ true, true, false, false } };
    try std.testing.expectEqual(FlipStatus.failed, runFlip(dead1.exec()));
    var dead2: Script = .{ .results = &.{ true, true, false, true, false } };
    try std.testing.expectEqual(FlipStatus.failed, runFlip(dead2.exec()));
}
