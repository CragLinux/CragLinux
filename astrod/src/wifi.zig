//! Wifi backend over iwd's D-Bus surface (net.connman.iwd), AD-015: iwd
//! manages wifi ONLY (EnableNetworkConfiguration=false via the overlay's
//! /etc/iwd/main.conf); dhcpcd owns addressing; astrod is the policy
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
//! (network.wifi.connection {ssid, psk}); astrod renders it as an iwd
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

/// Event types published here (followup: mirror as events.types consts).
pub const event_wifi_state = events_mod.types.network_wifi_state;
pub const event_wifi_scan_done = events_mod.types.network_wifi_scan_done;

/// iwd object paths are /net/connman/iwd/<phy>/<ifindex>/<ssid-hex>_<sec>
/// — ssid-hex is at most 64 chars, so 256 covers everything.
const max_path_len = 256;
/// How long connect() waits for a just-scanned ssid to appear before
/// falling back to iwd autoconnect (profile is already on disk).
const connect_scan_wait_ms: u64 = 5000;

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

/// Build a State snapshot from the model (no rssi — that needs a bus
/// call and is layered on by Wifi.state). Strings referencing the model
/// are duped into `allocator`; static fallbacks ("unavailable",
/// "unknown") are literals — callers use a per-request arena and never
/// free fields individually.
fn modelState(model: *const Model, allocator: std.mem.Allocator) error{OutOfMemory}!State {
    var st: State = .{
        .radio_present = false,
        .powered = false,
        .mode = .off,
        .connected_ssid = null,
        .rssi_dbm = null,
        .station_state = "unavailable",
    };
    var chosen: ?*const Device = null;
    for (model.devices.items) |*d| {
        if (chosen == null) chosen = d;
        if (d.has_station) {
            chosen = d;
            break;
        }
    }
    const dev = chosen orelse return st;
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
        const sta = self.stationPathZ(&sbuf) orelse return error.NoRadio;
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
        const sta = self.stationPathZ(&sbuf) orelse return error.NoRadio;
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
        self.tryConnect(ssid, if (psk.len == 0) Security.open else .psk);
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
            for (self.model.devices.items) |*d| {
                if (d.has_station) {
                    sta = std.fmt.bufPrintZ(&sbuf, "{s}", .{d.path}) catch null;
                    break;
                }
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
        for (self.model.devices.items) |*d| {
            if (d.has_station) return std.fmt.bufPrintZ(buf, "{s}", .{d.path}) catch null;
        }
        return null;
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
    /// when the network appears.
    fn tryConnect(self: *Wifi, ssid: []const u8, sec: Security) void {
        var pbuf: [max_path_len]u8 = undefined;
        if (self.findNetworkPathZ(&pbuf, ssid, sec)) |path| return self.connectNetworkPath(path);

        var sbuf: [max_path_len]u8 = undefined;
        const sta = self.stationPathZ(&sbuf) orelse return;
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
    }

    fn connectNetworkPath(self: *Wifi, path: [:0]const u8) void {
        // Network.Connect ("" args — iwd-3.12 src/network.c:2165) replies
        // only once the attempt settles; sd_bus_call waits (default
        // timeout) with bus.mu held, which delays signal dispatch a few
        // seconds worst-case. Accepted for v1 (single caller, rare op).
        if (self.bus.callMethod(iwd_service, path, network_interface, "Connect", &.{})) |reply| {
            var m = reply;
            m.deinit();
        } else |err| {
            std.log.warn("wifi: Network.Connect failed: {s} ({s})", .{ @errorName(err), self.bus.lastDbusError() });
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
            for (self.model.devices.items) |*d| {
                if (!d.has_station) continue;
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
                break;
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
    if (res.station_state_changed) self.publishStateEvent();
}

/// Module global set by main once the backend is constructed (update.zig
/// discipline); handlers answer 501/503 while null.
pub var global: ?*Wifi = null;

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
    const dotted = try ssidFileName(a, "astro.lan", .psk);
    defer a.free(dotted);
    try std.testing.expectEqualStrings("=617374726f2e6c616e.psk", dotted);

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

    try writeProfile(a, dir, "astro-test", "hunter22-secret");
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/astro-test.psk", .{dir});
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
    try writeProfile(a, dir, "astro.lan", "");
    var open_buf: [200]u8 = undefined;
    const open_path = try std.fmt.bufPrint(&open_buf, "{s}/=617374726f2e6c616e.open", .{dir});
    try std.testing.expect(fsutil.pathExists(open_path));

    removeProfiles(a, dir, "astro-test");
    removeProfiles(a, dir, "astro.lan");
    try std.testing.expect(!fsutil.pathExists(path));
    try std.testing.expect(!fsutil.pathExists(open_path));

    try std.testing.expectError(error.InvalidArgument, writeProfile(a, dir, "", "hunter22"));
}

// Model fixtures: ObjectEntry slices shaped exactly like bus.zig's
// readManagedObjects output (the Message→tree parsing itself is covered
// by bus.zig's socketpair tests against iwd's wire shapes).

const t_dev_path = "/net/connman/iwd/0/3";
const t_net_path = "/net/connman/iwd/0/3/617374726f2d74657374_psk";
const t_known_path = "/net/connman/iwd/617374726f2d74657374_psk";

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
        .{ .name = "Name", .value = .{ .s = "astro-test" } },
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
        .{ .name = "Name", .value = .{ .s = "astro-test" } },
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
    try std.testing.expectEqualStrings("astro-test", net.name);
    try std.testing.expectEqual(@as(?Security, .psk), net.security);
    try std.testing.expect(net.known);
    try std.testing.expect(!net.connected);
    try std.testing.expectEqualStrings(t_dev_path, net.device);

    // WEP maps to null security (unsupported by iwd, filtered from lists).
    try std.testing.expect(model.findNet("/net/connman/iwd/0/3/6c6567616379_wep").?.security == null);

    const known = model.findKnown(t_known_path).?;
    try std.testing.expectEqualStrings("astro-test", known.name);

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
    try std.testing.expectEqualStrings("astro-test", st.connected_ssid.?);

    // Powered off: mode reads off even though iftype says station.
    var off = [_]bus_mod.Prop{.{ .name = "Powered", .value = .{ .b = false } }};
    _ = model.applyInterface(t_dev_path, device_interface, &off, &.{});
    st = try modelState(&model, arena);
    try std.testing.expectEqual(Mode.off, st.mode);
    try std.testing.expect(!st.powered);
}

test "live iwd backend (manual: ASTRO_LIVE_IWD=1 against a real bus + iwd)" {
    if (std.c.getenv("ASTRO_LIVE_IWD") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var st = try store_mod.Store.load(gpa, "/tmp/astro-live-iwd.json");
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
