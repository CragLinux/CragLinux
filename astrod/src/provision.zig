//! Provisioning state machine (docs/07 §4, M3 phase 4).
//!
//! factory → provisioning → provisioned, persisted in the store
//! (system.provisioning). Two layers:
//!
//!  - the PURE core: `step` consumes (state, ap_active, event,
//!    observation) and returns a Decision — the next state plus the
//!    effects the caller must execute (enter/leave AP, persist, mDNS
//!    re-announce). No I/O; the whole transition table is unit-testable.
//!  - the MECHANICS: `Manager` wires the core to reality — startup
//!    evaluation from the store, link-carrier/address kernel events
//!    (its own link.Monitor), netconf lease + wifi state events (an
//!    internal EventBus subscription), periodic re-observation, and the
//!    effects (wifi.zig AP flip, mdns.zig announce, store persist,
//!    system.provisioned event).
//!
//! Transition rules implemented (docs/07 §4 diagram + baked decisions):
//!  - astrod startup with no usable network config: factory → provisioning.
//!  - valid config applied + connectivity verified → provisioned.
//!    "Connectivity verified" v1 = the interface has an address AND a
//!    default route exists. RECORDED DEVIATION from docs/07 §4's
//!    "gateway reachable": gateway ping is deferred — a lease whose
//!    gateway silently drops ICMP would false-negative forever, and the
//!    address+default-route pair is what the API actually needs to be
//!    reachable. Revisit with the connectivity-guard work (docs/06 §7).
//!  - Wired path (always on): unprovisioned + ethernet carrier + DHCP
//!    lease → the API is reachable on that LAN (token still required);
//!    Decision.wired_available surfaces it. Product policy
//!    "wired-is-provisioned" is the store flag api.wired_provisions
//!    (default false, additive): with it set, a verified wired lease
//!    promotes to provisioned without any wifi config.
//!  - AP captive portal: in provisioning with no ethernet carrier (and
//!    api.ap_provisioning enabled), enter AP mode. PUT wifi/connection
//!    while the AP is up → leave AP (the single-radio flip) and attempt
//!    the station connect; on failure the AP comes back (the
//!    wrong-password loop must be survivable); on success + connectivity
//!    verified → provisioned, and the AP never returns (enter_ap is
//!    unreachable from provisioned by construction).
//!  - Factory reset → factory (from any state, AP torn down).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const store_mod = @import("store.zig");
const events_mod = @import("events.zig");
const link = @import("link.zig");
const netconf = @import("netconf.zig");
const wifi_mod = @import("wifi.zig");
const mdns = @import("mdns.zig");
const sync = @import("sync.zig");
const fsutil = @import("fsutil.zig");

/// The persisted states (store system.provisioning wire strings).
pub const State = enum {
    factory,
    provisioning,
    provisioned,

    pub fn jsonName(self: State) []const u8 {
        return @tagName(self);
    }

    /// Parse the store's string; null for unknown values (a corrupt or
    /// future document must not crash the daemon — callers default to
    /// .factory, matching the store default).
    pub fn parse(s: []const u8) ?State {
        return std.meta.stringToEnum(State, s);
    }
};

/// What the daemon can observe when a step runs. Assembled by the caller
/// from the store (config presence, flags) and the link/netconf/wifi
/// subsystems (carrier, leases, connect state).
pub const Observation = struct {
    /// A usable network config exists in the store: a wifi connection
    /// profile, or a static ethernet config (plain-DHCP-by-default wired
    /// needs no config and is covered by the wired path instead).
    has_network_config: bool = false,
    /// Any ethernet interface has carrier (IFF_LOWER_UP).
    eth_carrier: bool = false,
    /// Any ethernet interface holds a DHCP lease (or static address).
    eth_lease: bool = false,
    /// v1 connectivity check: some interface has an address AND a
    /// default route exists (see the module header for the recorded
    /// deviation from "gateway reachable").
    connectivity_verified: bool = false,
    /// Store api.wired_provisions (product policy, default false).
    wired_provisions: bool = false,
    /// Store api.ap_provisioning (image default true), with a false
    /// system.ap.enabled_override folded in (force-down suppresses).
    ap_provisioning: bool = false,
    /// system.ap.enabled_override == true (docs/06 §5.2 manual force):
    /// the AP is wanted even with ethernet carrier present — the
    /// on-demand-AP product story and the hwsim e2e rig (slirp always
    /// has eth0 carrier, so the auto-trigger can never fire there).
    ap_forced: bool = false,
    /// A station connect attempt is in flight (Manager tracking): AP
    /// enter/leave edges hold still so an observe racing the flip can
    /// never bounce the radio mid-connect.
    connect_in_flight: bool = false,
};

/// What happened. `observe` covers every input edge that is not one of
/// the named events: link/lease changes, periodic reconciliation, wifi
/// state transitions reported by iwd.
pub const Event = enum {
    /// astrod startup (after store load).
    startup,
    /// Link/lease/wifi observation changed, or periodic re-evaluation.
    observe,
    /// PUT /network/wifi/connection accepted: a station connect attempt
    /// begins (while in AP mode this is the AP→station flip trigger).
    wifi_connect_started,
    /// The station connect attempt failed (bad PSK, out of range…).
    wifi_connect_failed,
    /// The station reports connected (address/route may still be
    /// pending; promotion happens on the next observe with
    /// connectivity_verified).
    wifi_connect_succeeded,
    /// POST /system/factory-reset accepted (the wipe happens at next
    /// boot via data-mount; the machine returns to factory immediately
    /// so the API narrates truthfully until the reboot).
    factory_reset,
};

pub const ApAction = enum { none, enter, leave };

/// What the caller must do after a step. Effects are edge-triggered:
/// `ap` is .enter only when the AP was down, .leave only when it was up
/// (the caller feeds back ap_active), and persist/announce fire only on
/// an actual state change.
pub const Decision = struct {
    next: State,
    ap: ApAction = .none,
    /// State changed: persist system.provisioning to the store.
    persist: bool = false,
    /// State changed: mDNS must re-announce (TXT carries provisioning=).
    announce: bool = false,
    /// Wired path marker (docs/07 §4): unprovisioned with an ethernet
    /// lease — the API is reachable on that LAN for provisioning
    /// purposes. Surfacing only; no transition unless wired_provisions.
    wired_available: bool = false,
};

/// The pure transition function. `ap_active` is whether the AP is
/// currently up (tracked by the caller/Machine, not persisted).
pub fn step(state: State, ap_active: bool, event: Event, obs: Observation) Decision {
    // Factory reset wins from any state.
    if (event == .factory_reset) {
        return .{
            .next = .factory,
            .ap = if (ap_active) .leave else .none,
            .persist = state != .factory,
            .announce = state != .factory,
        };
    }

    switch (state) {
        // Terminal until factory reset: the AP never returns, no wired
        // marker, nothing to do (docs/07 §4 "AP never returns").
        .provisioned => return .{
            .next = .provisioned,
            // Defensive: if the caller somehow reaches provisioned with
            // the AP still up (connect raced promotion), tear it down.
            .ap = if (ap_active) .leave else .none,
        },

        .factory, .provisioning => {
            const wired_available = obs.eth_lease;

            // Promotion: valid config applied + connectivity verified,
            // or the wired-is-provisioned product policy.
            const config_path = obs.has_network_config;
            const wired_path = obs.eth_lease and obs.wired_provisions;
            if (obs.connectivity_verified and (config_path or wired_path)) {
                return .{
                    .next = .provisioned,
                    .ap = if (ap_active) .leave else .none,
                    .persist = true,
                    .announce = true,
                };
            }

            // factory → provisioning happens at startup with no usable
            // network config (docs/07 §4 diagram edge).
            var next = state;
            var changed = false;
            if (state == .factory and event == .startup and !obs.has_network_config) {
                next = .provisioning;
                changed = true;
            }

            // AP policy (only ever in provisioning; factory reaches
            // provisioning first via the startup edge above, so a
            // freshly transitioned machine enters AP on this same step).
            // The AP is WANTED when forced (enabled_override=true) or on
            // the docs/07 §4 auto-trigger (enabled + no eth carrier);
            // both edges hold still while a connect attempt is in
            // flight so observes racing the flip cannot bounce the
            // radio (the failed/succeeded event settles it).
            var ap: ApAction = .none;
            if (next == .provisioning) {
                const want_ap = obs.ap_forced or (obs.ap_provisioning and !obs.eth_carrier);
                switch (event) {
                    // The single-radio flip: an accepted station connect
                    // takes the AP down first (docs/07 §4 item 4).
                    .wifi_connect_started => {
                        if (ap_active) ap = .leave;
                    },
                    // Wrong-password loop survivability: the AP comes
                    // back when the attempt fails and the trigger
                    // condition still holds (docs/07 §4 item 5). The
                    // symmetric edge tears a no-longer-wanted AP down
                    // (force-down override, or carrier appearing).
                    .wifi_connect_failed, .startup, .observe => {
                        if (obs.connect_in_flight) {
                            // hold
                        } else if (!ap_active and want_ap) {
                            ap = .enter;
                        } else if (ap_active and !want_ap) {
                            ap = .leave;
                        }
                    },
                    // Success: stay as we are; promotion happens via the
                    // connectivity_verified branch on a later observe.
                    .wifi_connect_succeeded => {},
                    .factory_reset => unreachable, // handled above
                }
            }

            return .{
                .next = next,
                .ap = ap,
                .persist = changed,
                .announce = changed,
                .wired_available = wired_available,
            };
        },
    }
}

/// Effect callbacks the fill implements (wifi AP flip, mDNS, store
/// persist). Function-pointer + context style, same shape as
/// netconf.LeaseHandler, so the Machine stays free of subsystem imports.
pub const Effects = struct {
    ctx: ?*anyopaque = null,
    /// Bring the provisioning AP up (render profile + iwd StartProfile).
    enterAp: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Tear the AP down (iwd Stop + profile cleanup).
    leaveAp: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Persist the new state string to the store (system.provisioning).
    persistState: ?*const fn (ctx: ?*anyopaque, state: State) void = null,
    /// Re-announce mDNS with the new provisioning state in TXT.
    announceMdns: ?*const fn (ctx: ?*anyopaque, state: State) void = null,
};

/// Stateful wrapper: tracks (state, ap_active, wired_available) and runs
/// the effects a Decision demands. NOT thread-safe — the fill drives it
/// from one reconciliation context (callers on other threads go through
/// that context, mirroring the netconf.Manager discipline).
pub const Machine = struct {
    state: State,
    ap_active: bool = false,
    wired_available: bool = false,
    effects: Effects = .{},

    pub fn init(initial: State, effects: Effects) Machine {
        return .{ .state = initial, .effects = effects };
    }

    /// Feed one event + observation through the pure table and execute
    /// the resulting effects. Returns the Decision for observability.
    pub fn handle(self: *Machine, event: Event, obs: Observation) Decision {
        const d = step(self.state, self.ap_active, event, obs);
        self.state = d.next;
        self.wired_available = d.wired_available;
        switch (d.ap) {
            .enter => {
                self.ap_active = true;
                if (self.effects.enterAp) |f| f(self.effects.ctx);
            },
            .leave => {
                self.ap_active = false;
                if (self.effects.leaveAp) |f| f(self.effects.ctx);
            },
            .none => {},
        }
        if (d.persist) if (self.effects.persistState) |f| f(self.effects.ctx, d.next);
        if (d.announce) if (self.effects.announceMdns) |f| f(self.effects.ctx, d.next);
        return d;
    }
};

// ---- mechanics (phase-4 fill): observation + event wiring ------------------

/// Safety-net re-observation interval; edges normally arrive as kernel
/// or bus events well before this fires.
pub const reconcile_interval_ms: u64 = 30_000;
pub const proc_route_path = "/proc/net/route";

/// Kernel-derived half of an Observation (the store-derived half is
/// assembled by the Manager). Injectable for tests via Manager.probe_fn.
pub const NetProbe = struct {
    eth_carrier: bool = false,
    eth_lease: bool = false,
    /// Any non-loopback, non-link-local address on any interface.
    has_addr: bool = false,
    /// An IPv4 default route exists.
    default_route: bool = false,
};

pub const ProbeFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) NetProbe;

/// True for addresses that indicate real network attachment: loopback,
/// v4 link-local (169.254/16) and v6 link-local (fe80::/10) are noise.
pub fn isGlobalAddr(a: *const link.Addr) bool {
    const b = a.bytes;
    if (a.family == posix.AF.INET) {
        if (b[0] == 127) return false;
        if (b[0] == 169 and b[1] == 254) return false;
        return true;
    }
    if (a.family == posix.AF.INET6) {
        const zero_prefix = blk: {
            for (b[0..15]) |x| if (x != 0) break :blk false;
            break :blk true;
        };
        if (zero_prefix and b[15] == 1) return false; // ::1
        if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return false; // fe80::/10
        return true;
    }
    return false;
}

/// Parse /proc/net/route (stable kernel text ABI: header line, then
/// "Iface\tDestination\tGateway\tFlags\t…" with hex fields). A default
/// route is Destination 00000000 with RTF_UP (0x1) set.
///
/// RECORDED DEVIATION: this is IPv4-only — matching the v4-only API
/// listeners (main.zig AD-014 posture). A v6-only deployment would need
/// /proc/net/ipv6_route or, better, an RTM_GETROUTE dump in link.zig
/// (the netlink home for route observation — see the phase followups).
pub fn hasDefaultRouteProc(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // Iface
        const dest = fields.next() orelse continue;
        _ = fields.next() orelse continue; // Gateway
        const flags_s = fields.next() orelse continue;
        if (!std.mem.eql(u8, dest, "00000000")) continue;
        const flags = std.fmt.parseInt(u32, flags_s, 16) catch continue;
        if (flags & 0x1 != 0) return true; // RTF_UP
    }
    return false;
}

/// The live probe: link.dump for carrier/addresses, netconf lease
/// exports for the wired-lease fact, /proc/net/route for the default
/// route. Every source degrades to "absent" on failure — a broken
/// observation channel must never wedge the state machine, only delay
/// promotion.
pub fn liveProbe(arena: std.mem.Allocator) NetProbe {
    var p: NetProbe = .{};
    if (link.dump(arena)) |ifaces| {
        defer link.freeIfaces(arena, ifaces);
        for (ifaces) |*iface| {
            const class = netconf.classOfInterface(iface.name());
            if (std.mem.eql(u8, class, "loopback")) continue;
            const eth = std.mem.eql(u8, class, "ethernet");
            if (eth and iface.carrier) p.eth_carrier = true;
            for (iface.addrs) |*a| {
                if (!isGlobalAddr(a)) continue;
                p.has_addr = true;
                // A global v4 address on wired covers both DHCP and
                // static ("lease" in the docs/07 §4 loose sense).
                if (eth and a.family == posix.AF.INET) p.eth_lease = true;
            }
        }
    } else |_| {}
    // Lease exports also count: they cover the short window between the
    // hook writing the file and the address observation, and they are
    // what netconf's own ethernet.state events narrate.
    if (netconf.readLeases(arena, netconf.lease_dir)) |leases| {
        for (leases) |*l| {
            if (l.address != null and std.mem.eql(u8, netconf.classOfInterface(l.iface), "ethernet"))
                p.eth_lease = true;
        }
    } else |_| {}
    if (fsutil.readFileAlloc(arena, proc_route_path, 64 * 1024)) |txt| {
        defer arena.free(txt);
        p.default_route = hasDefaultRouteProc(txt);
    } else |_| {}
    return p;
}

fn liveProbeFn(_: ?*anyopaque, arena: std.mem.Allocator) NetProbe {
    return liveProbe(arena);
}

/// Map an iwd station-state string (network.wifi.state events) onto the
/// machine's connect-attempt events. `in_flight` tracks an attempt in
/// progress (set either by notifyWifiConnectStarted from the PUT
/// handler or by an observed "connecting").
pub const WifiMap = struct { event: ?Event, in_flight: bool };

pub fn mapWifiState(state: []const u8, in_flight: bool) WifiMap {
    if (std.mem.eql(u8, state, "connecting")) {
        return .{ .event = if (in_flight) null else .wifi_connect_started, .in_flight = true };
    }
    if (std.mem.eql(u8, state, "connected")) {
        return .{ .event = if (in_flight) .wifi_connect_succeeded else .observe, .in_flight = false };
    }
    if (std.mem.eql(u8, state, "disconnected")) {
        return .{ .event = if (in_flight) .wifi_connect_failed else .observe, .in_flight = false };
    }
    // roaming / unknown / unavailable: just re-observe.
    return .{ .event = .observe, .in_flight = in_flight };
}

/// The provisioning reconciler. Owns the Machine and feeds it from four
/// sources: startup evaluation, its own link.Monitor (carrier/address
/// kernel events), an internal EventBus subscription (netconf lease +
/// wifi state events — NOTE: consumes one of events.max_subscribers,
/// leaving 15 for SSE clients), and a periodic safety net. Handlers
/// (fill work: PUT wifi/connection, POST factory-reset) reach it via
/// `global` and the notify* entry points; every machine step runs under
/// `mu`, satisfying the Machine's single-context contract.
pub const Manager = struct {
    gpa: std.mem.Allocator,
    st: *store_mod.Store,
    event_bus: ?*events_mod.EventBus = null,
    responder: ?*mdns.Responder = null,
    wifi: ?*wifi_mod.Wifi = null,
    /// Owned trimmed copy; seeds the AP SSID/PSK derivation.
    machine_id: []const u8,
    machine: Machine,
    /// Guards machine, pending queue, dirty and connect_in_flight.
    mu: sync.Mutex = .{},
    pending: [8]Event = undefined,
    pending_len: usize = 0,
    /// A plain re-observation is wanted (link event / queue overflow).
    dirty: bool = false,
    /// A station connect attempt is in progress (mapWifiState contract).
    connect_in_flight: bool = false,
    wake_fd: posix.fd_t = -1,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    sub_thread: ?std.Thread = null,
    monitor: ?*link.Monitor = null,
    probe_ctx: ?*anyopaque = null,
    probe_fn: ProbeFn = liveProbeFn,
    interval_ms: u64 = reconcile_interval_ms,
    /// Optional external AP controller (main wires portal.ApController's
    /// effectEnterAp/effectLeaveAp here): when set, the enter/leave
    /// effects run the full portal chain (wifi AP + nft redirects + DNS
    /// catch-all + HTTP listener) instead of the bare wifi flip.
    ap_enter: ?*const fn (ctx: ?*anyopaque) void = null,
    ap_leave: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Truth check after effects run: the Machine tracks ap_active
    /// optimistically (it flips BEFORE the effect executes), so a
    /// failed enterAp would otherwise wedge it in "up" and never retry
    /// (the ApController's "next observe retries" contract). When set,
    /// process() re-syncs machine.ap_active down to reality.
    ap_is_active: ?*const fn (ctx: ?*anyopaque) bool = null,
    ap_ctx: ?*anyopaque = null,

    pub const InitOptions = struct {
        event_bus: ?*events_mod.EventBus = null,
        responder: ?*mdns.Responder = null,
        wifi: ?*wifi_mod.Wifi = null,
        machine_id: []const u8 = "",
    };

    /// Initial state comes from the store (system.provisioning);
    /// unknown/corrupt strings default to .factory (the store default).
    pub fn init(gpa: std.mem.Allocator, st: *store_mod.Store, opts: InitOptions) error{OutOfMemory}!*Manager {
        const self = try gpa.create(Manager);
        errdefer gpa.destroy(self);
        const mid = try gpa.dupe(u8, std.mem.trim(u8, opts.machine_id, " \t\r\n"));
        self.* = .{
            .gpa = gpa,
            .st = st,
            .event_bus = opts.event_bus,
            .responder = opts.responder,
            .wifi = opts.wifi,
            .machine_id = mid,
            .machine = Machine.init(State.parse(st.getProvisioning()) orelse .factory, .{}),
        };
        self.machine.effects = .{
            .ctx = self,
            .enterAp = fxEnterAp,
            .leaveAp = fxLeaveAp,
            .persistState = fxPersist,
            .announceMdns = fxAnnounce,
        };
        return self;
    }

    pub fn deinit(self: *Manager) void {
        self.stop();
        self.gpa.free(self.machine_id);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Startup evaluation + event-source spawn. Every source degrades
    /// individually (logged): a sandboxed netlink or a missing bus never
    /// blocks the daemon — the periodic loop still reconciles. The
    /// docs/07 §4 startup edge runs as the reconcile thread's FIRST
    /// step, not here: entering AP mode at boot (profile render + iwd
    /// netconfig window + StartProfile) can take tens of seconds, and
    /// astrod's readiness (listener bind + dinit ready-fd) must never
    /// wait on it — boot success does not depend on being provisioned.
    pub fn start(self: *Manager) void {
        if (link.Monitor.init(self.gpa, onLinkEvent, self)) |mon| {
            self.monitor = mon;
            mon.start() catch |err| {
                std.log.warn("provision: link monitor thread failed ({t})", .{err});
                mon.deinit();
                self.monitor = null;
            };
        } else |err| {
            std.log.warn("provision: link monitor unavailable ({t}); carrier edges degrade to polling", .{err});
        }

        const erc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(erc) == .SUCCESS) {
            self.wake_fd = @intCast(erc);
            self.stop_flag.store(false, .release);
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch blk: {
                std.log.warn("provision: reconcile thread failed to start", .{});
                _ = linux.close(self.wake_fd);
                self.wake_fd = -1;
                break :blk null;
            };
        } else {
            std.log.warn("provision: eventfd unavailable; reconcile loop disabled", .{});
        }
        if (self.thread == null) {
            // Degraded fallback: no thread will ever run the startup
            // edge, so evaluate it here (blocking is the lesser evil).
            _ = self.process(.startup);
        }

        if (self.event_bus != null and self.thread != null) {
            self.sub_thread = std.Thread.spawn(.{}, subRun, .{self}) catch blk: {
                std.log.warn("provision: event subscriber thread failed to start", .{});
                break :blk null;
            };
        }
    }

    pub fn stop(self: *Manager) void {
        self.stop_flag.store(true, .release);
        if (self.monitor) |mon| {
            mon.deinit();
            self.monitor = null;
        }
        if (self.thread) |t| {
            self.wake();
            t.join();
            self.thread = null;
        }
        if (self.sub_thread) |t| {
            t.join(); // bounded by the 500 ms next() timeout
            self.sub_thread = null;
        }
        if (self.wake_fd >= 0) {
            _ = linux.close(self.wake_fd);
            self.wake_fd = -1;
        }
    }

    // -- accessors (GET /system assembly, fill work) --

    pub fn currentState(self: *Manager) State {
        self.mu.lock();
        defer self.mu.unlock();
        return self.machine.state;
    }

    pub fn wiredAvailable(self: *Manager) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.machine.wired_available;
    }

    pub fn apActive(self: *Manager) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.machine.ap_active;
    }

    // -- handler entry points (dispatched via `global` by the fill) --

    /// PUT /network/wifi/connection accepted: a station attempt begins
    /// (the AP flip trigger). Also arms the mapWifiState attempt window.
    pub fn notifyWifiConnectStarted(self: *Manager) void {
        self.mu.lock();
        self.connect_in_flight = true;
        self.mu.unlock();
        self.enqueue(.wifi_connect_started);
    }

    pub fn notifyWifiConnectFailed(self: *Manager) void {
        self.mu.lock();
        self.connect_in_flight = false;
        self.mu.unlock();
        self.enqueue(.wifi_connect_failed);
    }

    pub fn notifyWifiConnectSucceeded(self: *Manager) void {
        self.mu.lock();
        self.connect_in_flight = false;
        self.mu.unlock();
        self.enqueue(.wifi_connect_succeeded);
    }

    /// POST /system/factory-reset accepted (the wipe runs at next boot).
    pub fn notifyFactoryReset(self: *Manager) void {
        self.enqueue(.factory_reset);
    }

    /// The deferred AP→station flip (PUT wifi/connection on the AP
    /// surface; main.zig DeferredAction.wifi_flip): SYNCHRONOUS on the
    /// caller's thread — the AP must be down before the single radio can
    /// try the station connect (docs/07 §4 item 4), and the failed/
    /// succeeded outcome must feed back before the in-flight window
    /// closes (item 5, the wrong-password loop). The connect_in_flight
    /// flag keeps concurrent observes from bouncing the AP mid-flip.
    pub fn flipConnect(self: *Manager, ssid: []const u8, psk: []const u8) void {
        self.mu.lock();
        self.connect_in_flight = true;
        self.mu.unlock();
        _ = self.process(.wifi_connect_started); // leaveAp effect runs inline
        const ok = blk: {
            const w = self.wifi orelse break :blk false;
            break :blk w.connectAttempt(ssid, psk) catch false;
        };
        self.mu.lock();
        self.connect_in_flight = false;
        self.mu.unlock();
        _ = self.process(if (ok) .wifi_connect_succeeded else .wifi_connect_failed);
    }

    /// Request a re-observation (link events, external nudges).
    pub fn pokeObserve(self: *Manager) void {
        self.mu.lock();
        self.dirty = true;
        self.mu.unlock();
        self.wake();
    }

    /// Gather a fresh observation and feed one event through the
    /// machine (single mu-guarded step; also the test seam).
    pub fn process(self: *Manager, event: Event) Decision {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const obs = self.observeNow(arena.allocator());
        self.mu.lock();
        defer self.mu.unlock();
        const d = self.machine.handle(event, obs);
        // Re-sync the optimistic ap_active with the controller's truth:
        // a failed enterAp must leave the machine in "down" so the next
        // observe retries instead of wedging (see ap_is_active).
        if (self.ap_is_active) |f| {
            if (self.machine.ap_active and !f(self.ap_ctx)) self.machine.ap_active = false;
        }
        return d;
    }

    /// Drain queued named events (each with a fresh observation), then
    /// one plain observe when poked. Runs on the reconcile thread; also
    /// the test seam for scripted scenarios.
    pub fn drainPending(self: *Manager) void {
        while (true) {
            self.mu.lock();
            var ev: ?Event = null;
            if (self.pending_len > 0) {
                ev = self.pending[0];
                std.mem.copyForwards(Event, self.pending[0 .. self.pending_len - 1], self.pending[1..self.pending_len]);
                self.pending_len -= 1;
            } else if (self.dirty) {
                self.dirty = false;
                ev = .observe;
            }
            self.mu.unlock();
            _ = self.process(ev orelse return);
        }
    }

    // -- observation assembly --

    fn observeNow(self: *Manager, arena: std.mem.Allocator) Observation {
        const probe = self.probe_fn(self.probe_ctx, arena);
        const api = self.st.getApi();
        // system.ap.enabled_override (docs/06 §5.2 manual control):
        // false suppresses, true FORCES (even with eth carrier — the
        // auto-trigger's carrier condition applies only to the
        // machine-decided path), null = the machine decides.
        const override = self.st.getApEnabledOverride();
        self.mu.lock();
        const in_flight = self.connect_in_flight;
        self.mu.unlock();
        return .{
            .has_network_config = self.hasNetworkConfig(),
            .eth_carrier = probe.eth_carrier,
            .eth_lease = probe.eth_lease,
            .connectivity_verified = probe.has_addr and probe.default_route,
            .wired_provisions = api.wired_provisions,
            .ap_provisioning = override orelse api.ap_provisioning,
            .ap_forced = override == true,
            .connect_in_flight = in_flight,
        };
    }

    /// "Usable network config exists": a wifi connection profile or a
    /// static ethernet block (plain wired DHCP needs no config and is
    /// the wired path's business instead).
    pub fn hasNetworkConfig(self: *Manager) bool {
        if (self.st.getWifiConnection() != null) return true;
        self.st.mu.lockShared();
        defer self.st.mu.unlockShared();
        var it = self.st.config.network.ethernet.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.ipv4.mode, "static")) return true;
        }
        return false;
    }

    // -- effects (Machine callbacks; ctx is the Manager) --

    fn fxEnterAp(ctx: ?*anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(ctx.?));
        if (self.ap_enter) |f| {
            f(self.ap_ctx); // the portal ApController owns the full chain
            return;
        }
        const w = self.wifi orelse {
            std.log.warn("provision: AP wanted but no wifi backend; portal unavailable", .{});
            return;
        };
        var sbuf: [32]u8 = undefined;
        var pbuf: [16]u8 = undefined;
        const ssid = wifi_mod.deriveApSsid(&sbuf, self.machine_id);
        const psk = wifi_mod.deriveApPsk(&pbuf, self.machine_id);
        // comptime probe: the AP entry points live at wifi.zig file scope
        // in the spine and move into Wifi as the fill lands — accept both.
        const call = if (@hasDecl(wifi_mod.Wifi, "apStart")) wifi_mod.Wifi.apStart else wifi_mod.apStart;
        call(w, ssid, psk) catch |err| {
            std.log.warn("provision: AP start failed ({t})", .{err});
        };
    }

    fn fxLeaveAp(ctx: ?*anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(ctx.?));
        if (self.ap_leave) |f| {
            f(self.ap_ctx);
            return;
        }
        const w = self.wifi orelse return;
        const call = if (@hasDecl(wifi_mod.Wifi, "apStop")) wifi_mod.Wifi.apStop else wifi_mod.apStop;
        call(w) catch |err| {
            std.log.warn("provision: AP stop failed ({t})", .{err});
        };
    }

    fn fxPersist(ctx: ?*anyopaque, state: State) void {
        const self: *Manager = @ptrCast(@alignCast(ctx.?));
        self.st.setProvisioning(state.jsonName()) catch |err| {
            std.log.warn("provision: persisting state '{s}' failed ({t})", .{ state.jsonName(), err });
        };
    }

    fn fxAnnounce(ctx: ?*anyopaque, state: State) void {
        const self: *Manager = @ptrCast(@alignCast(ctx.?));
        if (self.responder) |r| r.setProvisioningState(state.jsonName());
        if (state == .provisioned) {
            if (self.event_bus) |bus| {
                _ = bus.publishEnvelope(
                    events_mod.types.system_provisioned,
                    null,
                    "{\"state\":\"provisioned\"}",
                ) catch 0;
            }
        }
    }

    // -- event plumbing --

    fn enqueue(self: *Manager, event: Event) void {
        self.mu.lock();
        if (self.pending_len < self.pending.len) {
            self.pending[self.pending_len] = event;
            self.pending_len += 1;
        } else {
            // Overflow degrades to a re-observation — observations are
            // re-gathered per step, so no fact is lost, only an edge
            // label (acceptable: the machine re-derives from state).
            self.dirty = true;
        }
        self.mu.unlock();
        self.wake();
    }

    fn wake(self: *Manager) void {
        if (self.wake_fd < 0) return;
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, @ptrCast(&one), 8);
    }

    /// link.Monitor callback (monitor thread): carrier/address changed.
    fn onLinkEvent(ctx: ?*anyopaque, event: link.Event) void {
        _ = event; // the observation is re-gathered wholesale
        const self: *Manager = @ptrCast(@alignCast(ctx.?));
        self.pokeObserve();
    }

    /// Reconcile thread: the startup edge first (see start()), then
    /// drain queued events on wake, re-observe on the interval safety
    /// net.
    fn run(self: *Manager) void {
        _ = self.process(.startup);
        while (!self.stop_flag.load(.acquire)) {
            var pfds = [_]posix.pollfd{
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            const timeout: i32 = @intCast(@min(self.interval_ms, std.math.maxInt(i32)));
            const n = posix.poll(&pfds, timeout) catch return;
            if (self.stop_flag.load(.acquire)) return;
            if (n == 0) {
                _ = self.process(.observe);
                continue;
            }
            if (pfds[0].revents & posix.POLL.IN != 0) {
                var drain: [8]u8 = undefined;
                _ = linux.read(self.wake_fd, &drain, 8);
                self.drainPending();
            }
        }
    }

    /// EventBus subscriber thread: netconf lease events
    /// (network.ethernet.state) trigger re-observation; wifi state
    /// events (network.wifi.state) map onto connect-attempt edges.
    fn subRun(self: *Manager) void {
        const bus = self.event_bus orelse return;
        const sub = bus.subscribe(null) catch |err| {
            std.log.warn("provision: event subscription failed ({t}); wifi/lease edges degrade to polling", .{err});
            return;
        };
        defer sub.cancel();
        while (!self.stop_flag.load(.acquire)) {
            const maybe = sub.next(500) catch continue; // Overflowed: cursor snapped, keep reading
            const ev = maybe orelse continue;
            self.handleBusEvent(ev.event_type, ev.payload);
        }
    }

    fn handleBusEvent(self: *Manager, event_type: []const u8, payload: []const u8) void {
        if (std.mem.eql(u8, event_type, events_mod.types.network_ethernet_state)) {
            self.pokeObserve();
            return;
        }
        if (!std.mem.eql(u8, event_type, events_mod.types.network_wifi_state)) return;
        const Envelope = struct {
            data: struct { state: []const u8 = "" } = .{},
        };
        var parsed = std.json.parseFromSlice(Envelope, self.gpa, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        self.mu.lock();
        const mapped = mapWifiState(parsed.value.data.state, self.connect_in_flight);
        self.connect_in_flight = mapped.in_flight;
        self.mu.unlock();
        if (mapped.event) |e| self.enqueue(e);
    }
};

/// Module global set by main once the manager is constructed (update.zig
/// discipline); the fill's HTTP handlers dispatch notify* through it.
pub var global: ?*Manager = null;

// ---- tests -----------------------------------------------------------------

test "State parse/jsonName round-trip; unknown strings are null" {
    try std.testing.expectEqual(State.factory, State.parse("factory").?);
    try std.testing.expectEqual(State.provisioning, State.parse("provisioning").?);
    try std.testing.expectEqual(State.provisioned, State.parse("provisioned").?);
    try std.testing.expect(State.parse("half-provisioned") == null);
    try std.testing.expect(State.parse("") == null);
    try std.testing.expectEqualStrings("provisioning", State.provisioning.jsonName());
}

test "startup with no usable config: factory enters provisioning (and AP when eligible)" {
    // No ethernet carrier + AP flag on → provisioning AND enter AP in
    // the same step (the freshly transitioned machine is AP-eligible).
    const d = step(.factory, false, .startup, .{ .ap_provisioning = true });
    try std.testing.expectEqual(State.provisioning, d.next);
    try std.testing.expectEqual(ApAction.enter, d.ap);
    try std.testing.expect(d.persist);
    try std.testing.expect(d.announce);

    // Ethernet carrier present → provisioning but NO AP (docs/07 §4:
    // the AP trigger is "no Ethernet carrier").
    const d2 = step(.factory, false, .startup, .{ .ap_provisioning = true, .eth_carrier = true });
    try std.testing.expectEqual(State.provisioning, d2.next);
    try std.testing.expectEqual(ApAction.none, d2.ap);

    // AP provisioning disabled by image flag → no AP either.
    const d3 = step(.factory, false, .startup, .{});
    try std.testing.expectEqual(State.provisioning, d3.next);
    try std.testing.expectEqual(ApAction.none, d3.ap);
}

test "startup with usable config: factory stays factory until connectivity verifies" {
    // Image pre-baked a config (docs/07 §4 direct factory → provisioned
    // edge): no provisioning detour, no AP.
    const waiting = step(.factory, false, .startup, .{ .has_network_config = true, .ap_provisioning = true });
    try std.testing.expectEqual(State.factory, waiting.next);
    try std.testing.expectEqual(ApAction.none, waiting.ap);
    try std.testing.expect(!waiting.persist);

    const done = step(.factory, false, .observe, .{
        .has_network_config = true,
        .connectivity_verified = true,
    });
    try std.testing.expectEqual(State.provisioned, done.next);
    try std.testing.expect(done.persist);
    try std.testing.expect(done.announce);
}

test "config + connectivity promotes provisioning to provisioned and tears the AP down" {
    const d = step(.provisioning, true, .observe, .{
        .has_network_config = true,
        .connectivity_verified = true,
        .ap_provisioning = true,
    });
    try std.testing.expectEqual(State.provisioned, d.next);
    try std.testing.expectEqual(ApAction.leave, d.ap);
    try std.testing.expect(d.persist);
    try std.testing.expect(d.announce);
}

test "connectivity without any config path does not promote" {
    // A default route with neither a stored config nor the wired flag
    // (e.g. plain wired DHCP on a wired_provisions=false product) keeps
    // the machine unprovisioned but marks wired availability.
    const d = step(.provisioning, false, .observe, .{
        .eth_carrier = true,
        .eth_lease = true,
        .connectivity_verified = true,
    });
    try std.testing.expectEqual(State.provisioning, d.next);
    try std.testing.expect(d.wired_available);
    try std.testing.expect(!d.persist);
}

test "wired path: lease surfaces wired_available; wired_provisions promotes" {
    // Flag off: marker only (docs/07 §4 "for provisioning purposes").
    const marker = step(.provisioning, false, .observe, .{
        .eth_carrier = true,
        .eth_lease = true,
        .connectivity_verified = true,
        .wired_provisions = false,
    });
    try std.testing.expectEqual(State.provisioning, marker.next);
    try std.testing.expect(marker.wired_available);

    // Flag on: the same observation provisions the device.
    const promoted = step(.provisioning, false, .observe, .{
        .eth_carrier = true,
        .eth_lease = true,
        .connectivity_verified = true,
        .wired_provisions = true,
    });
    try std.testing.expectEqual(State.provisioned, promoted.next);
    try std.testing.expect(promoted.persist);

    // Lease but no verified connectivity (no default route yet): wait.
    const waiting = step(.provisioning, false, .observe, .{
        .eth_carrier = true,
        .eth_lease = true,
        .wired_provisions = true,
    });
    try std.testing.expectEqual(State.provisioning, waiting.next);
    try std.testing.expect(waiting.wired_available);

    // The wired path also promotes straight from factory (diagram's
    // "ethernet DHCP succeeds and product policy says so" edge).
    const from_factory = step(.factory, false, .observe, .{
        .eth_carrier = true,
        .eth_lease = true,
        .connectivity_verified = true,
        .wired_provisions = true,
    });
    try std.testing.expectEqual(State.provisioned, from_factory.next);
}

test "AP enter/leave edges: connect flip, failure re-entry, idempotence" {
    const ap_obs: Observation = .{ .ap_provisioning = true };

    // observe with AP down → enter; with AP already up → no-op.
    try std.testing.expectEqual(ApAction.enter, step(.provisioning, false, .observe, ap_obs).ap);
    try std.testing.expectEqual(ApAction.none, step(.provisioning, true, .observe, ap_obs).ap);

    // The single-radio flip: connect_started with AP up → leave; with
    // AP already down → nothing to leave.
    try std.testing.expectEqual(ApAction.leave, step(.provisioning, true, .wifi_connect_started, ap_obs).ap);
    try std.testing.expectEqual(ApAction.none, step(.provisioning, false, .wifi_connect_started, ap_obs).ap);

    // Failure → AP back up (wrong-password loop, docs/07 §4 item 5)…
    try std.testing.expectEqual(ApAction.enter, step(.provisioning, false, .wifi_connect_failed, ap_obs).ap);
    // …but not when ethernet carrier appeared or AP mode is disabled.
    try std.testing.expectEqual(ApAction.none, step(.provisioning, false, .wifi_connect_failed, .{ .ap_provisioning = true, .eth_carrier = true }).ap);
    try std.testing.expectEqual(ApAction.none, step(.provisioning, false, .wifi_connect_failed, .{}).ap);

    // Success alone changes nothing (promotion needs connectivity on a
    // later observe); the AP stays down.
    const succ = step(.provisioning, false, .wifi_connect_succeeded, ap_obs);
    try std.testing.expectEqual(State.provisioning, succ.next);
    try std.testing.expectEqual(ApAction.none, succ.ap);
}

test "AP force/hold edges: override beats carrier, in-flight freezes, unwanted AP leaves" {
    // Forced (enabled_override=true): the AP is wanted even WITH
    // ethernet carrier — the on-demand story and the e2e rig (slirp
    // always has eth0 carrier).
    const forced: Observation = .{ .ap_provisioning = true, .ap_forced = true, .eth_carrier = true };
    try std.testing.expectEqual(ApAction.enter, step(.provisioning, false, .observe, forced).ap);
    try std.testing.expectEqual(ApAction.none, step(.provisioning, true, .observe, forced).ap);

    // A no-longer-wanted AP (force cleared with carrier present, or
    // force-down) is torn down on the next observe.
    const unwanted: Observation = .{ .ap_provisioning = true, .eth_carrier = true };
    try std.testing.expectEqual(ApAction.leave, step(.provisioning, true, .observe, unwanted).ap);
    try std.testing.expectEqual(ApAction.leave, step(.provisioning, true, .observe, .{}).ap);

    // In-flight connect freezes both edges: no enter (the flip is
    // mid-air with the AP down) and no leave (nothing may bounce the
    // radio until failed/succeeded settles the attempt).
    const busy_down: Observation = .{ .ap_provisioning = true, .connect_in_flight = true };
    try std.testing.expectEqual(ApAction.none, step(.provisioning, false, .observe, busy_down).ap);
    const busy_up: Observation = .{ .eth_carrier = true, .connect_in_flight = true };
    try std.testing.expectEqual(ApAction.none, step(.provisioning, true, .observe, busy_up).ap);

    // The flip trigger itself still wins while forced: connect_started
    // takes even a forced AP down (the PUT is explicit user intent).
    try std.testing.expectEqual(ApAction.leave, step(.provisioning, true, .wifi_connect_started, forced).ap);
}

test "provisioned is terminal: no AP, no wired marker, until factory reset" {
    const stay = step(.provisioned, false, .observe, .{ .ap_provisioning = true, .eth_lease = true });
    try std.testing.expectEqual(State.provisioned, stay.next);
    try std.testing.expectEqual(ApAction.none, stay.ap);
    try std.testing.expect(!stay.wired_available);
    try std.testing.expect(!stay.persist);

    // Defensive AP teardown if promotion raced the flip.
    try std.testing.expectEqual(ApAction.leave, step(.provisioned, true, .observe, .{}).ap);

    // Factory reset re-entry (docs/07 §4 diagram bottom edge).
    const reset = step(.provisioned, false, .factory_reset, .{});
    try std.testing.expectEqual(State.factory, reset.next);
    try std.testing.expect(reset.persist);
    try std.testing.expect(reset.announce);

    // Reset from provisioning with the AP up tears it down.
    const reset2 = step(.provisioning, true, .factory_reset, .{ .ap_provisioning = true });
    try std.testing.expectEqual(State.factory, reset2.next);
    try std.testing.expectEqual(ApAction.leave, reset2.ap);

    // Reset while already factory: no spurious persist/announce.
    const noop = step(.factory, false, .factory_reset, .{});
    try std.testing.expectEqual(State.factory, noop.next);
    try std.testing.expect(!noop.persist);
}

test "Machine executes effects and tracks ap_active across the portal round-trip" {
    const Trace = struct {
        var log: std.ArrayList(u8) = .empty;
        var alloc: std.mem.Allocator = undefined;
        fn enter(_: ?*anyopaque) void {
            log.append(alloc, 'A') catch unreachable; // Ap up
        }
        fn leave(_: ?*anyopaque) void {
            log.append(alloc, 'a') catch unreachable; // ap down
        }
        fn persist(_: ?*anyopaque, s: State) void {
            log.append(alloc, "fgd"[@intFromEnum(s)]) catch unreachable;
        }
        fn announce(_: ?*anyopaque, _: State) void {
            log.append(alloc, 'm') catch unreachable;
        }
    };
    Trace.alloc = std.testing.allocator;
    Trace.log = .empty;
    defer Trace.log.deinit(Trace.alloc);

    var m = Machine.init(.factory, .{
        .enterAp = Trace.enter,
        .leaveAp = Trace.leave,
        .persistState = Trace.persist,
        .announceMdns = Trace.announce,
    });

    // Startup, no config, no carrier → provisioning ('g') + announce + AP up.
    _ = m.handle(.startup, .{ .ap_provisioning = true });
    try std.testing.expectEqual(State.provisioning, m.state);
    try std.testing.expect(m.ap_active);

    // Portal submits credentials → AP flips down.
    _ = m.handle(.wifi_connect_started, .{ .ap_provisioning = true });
    try std.testing.expect(!m.ap_active);

    // Wrong password → AP back up.
    _ = m.handle(.wifi_connect_failed, .{ .ap_provisioning = true });
    try std.testing.expect(m.ap_active);

    // Second attempt succeeds → connectivity verifies → provisioned
    // ('d'), AP down for good.
    _ = m.handle(.wifi_connect_started, .{ .ap_provisioning = true, .has_network_config = true });
    _ = m.handle(.wifi_connect_succeeded, .{ .ap_provisioning = true, .has_network_config = true });
    _ = m.handle(.observe, .{ .ap_provisioning = true, .has_network_config = true, .connectivity_verified = true });
    try std.testing.expectEqual(State.provisioned, m.state);
    try std.testing.expect(!m.ap_active);

    // Effect order over the whole story.
    try std.testing.expectEqualStrings("Agm" ++ "a" ++ "A" ++ "a" ++ "dm", Trace.log.items);

    // Factory reset re-enters factory and persists.
    _ = m.handle(.factory_reset, .{});
    try std.testing.expectEqual(State.factory, m.state);
    try std.testing.expectEqualStrings("Agm" ++ "a" ++ "A" ++ "a" ++ "dm" ++ "fm", Trace.log.items);
}

test "Machine surfaces wired_available for GET /system" {
    var m = Machine.init(.provisioning, .{});
    _ = m.handle(.observe, .{ .eth_carrier = true, .eth_lease = true });
    try std.testing.expect(m.wired_available);
    _ = m.handle(.observe, .{});
    try std.testing.expect(!m.wired_available);
}

// ---- mechanics tests --------------------------------------------------------

test "hasDefaultRouteProc: default route detection over /proc/net/route text" {
    // Real-shaped table: header + a default route + a subnet route.
    const with_default =
        "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" ++
        "eth0\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n" ++
        "eth0\t0000000A\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n";
    try std.testing.expect(hasDefaultRouteProc(with_default));

    // Only the subnet route: no default.
    const no_default =
        "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" ++
        "eth0\t0000000A\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n";
    try std.testing.expect(!hasDefaultRouteProc(no_default));

    // A downed default route (RTF_UP clear) does not count.
    const down_default =
        "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" ++
        "eth0\t00000000\t0100000A\t0002\t0\t0\t100\t00000000\t0\t0\t0\n";
    try std.testing.expect(!hasDefaultRouteProc(down_default));

    // Empty/garbage degrade to false, never crash.
    try std.testing.expect(!hasDefaultRouteProc(""));
    try std.testing.expect(!hasDefaultRouteProc("not\ta\troute\ttable"));
}

test "isGlobalAddr filters loopback and link-local" {
    const v4 = struct {
        fn addr(b: [4]u8) link.Addr {
            var a: link.Addr = .{ .family = posix.AF.INET, .prefix = 24, .bytes = @splat(0) };
            @memcpy(a.bytes[0..4], &b);
            return a;
        }
    };
    var a1 = v4.addr(.{ 10, 0, 2, 15 });
    try std.testing.expect(isGlobalAddr(&a1));
    var a2 = v4.addr(.{ 127, 0, 0, 1 });
    try std.testing.expect(!isGlobalAddr(&a2));
    var a3 = v4.addr(.{ 169, 254, 3, 4 });
    try std.testing.expect(!isGlobalAddr(&a3));

    var ll: link.Addr = .{ .family = posix.AF.INET6, .prefix = 64, .bytes = @splat(0) };
    ll.bytes[0] = 0xfe;
    ll.bytes[1] = 0x80;
    ll.bytes[15] = 1;
    try std.testing.expect(!isGlobalAddr(&ll));

    var lo6: link.Addr = .{ .family = posix.AF.INET6, .prefix = 128, .bytes = @splat(0) };
    lo6.bytes[15] = 1; // ::1
    try std.testing.expect(!isGlobalAddr(&lo6));

    var g6: link.Addr = .{ .family = posix.AF.INET6, .prefix = 64, .bytes = @splat(0) };
    g6.bytes[0] = 0x20;
    g6.bytes[1] = 0x01;
    try std.testing.expect(isGlobalAddr(&g6));
}

test "mapWifiState: attempt window over iwd station states" {
    // connecting arms the window once.
    var r = mapWifiState("connecting", false);
    try std.testing.expectEqual(Event.wifi_connect_started, r.event.?);
    try std.testing.expect(r.in_flight);
    r = mapWifiState("connecting", true);
    try std.testing.expect(r.event == null); // no duplicate started
    try std.testing.expect(r.in_flight);

    // connected/disconnected resolve the attempt…
    r = mapWifiState("connected", true);
    try std.testing.expectEqual(Event.wifi_connect_succeeded, r.event.?);
    try std.testing.expect(!r.in_flight);
    r = mapWifiState("disconnected", true);
    try std.testing.expectEqual(Event.wifi_connect_failed, r.event.?);
    try std.testing.expect(!r.in_flight);

    // …and are plain observations outside one.
    r = mapWifiState("connected", false);
    try std.testing.expectEqual(Event.observe, r.event.?);
    r = mapWifiState("disconnected", false);
    try std.testing.expectEqual(Event.observe, r.event.?);

    // roaming/unknown keep the window and just re-observe.
    r = mapWifiState("roaming", true);
    try std.testing.expectEqual(Event.observe, r.event.?);
    try std.testing.expect(r.in_flight);
}

/// Scripted probe + effect trace shared by the Manager scenario tests
/// (zig runs tests serially; the container-level vars are safe).
const TestProbe = struct {
    var current: NetProbe = .{};
    fn probe(_: ?*anyopaque, _: std.mem.Allocator) NetProbe {
        return current;
    }
};

const MTrace = struct {
    var log: std.ArrayList(u8) = .empty;
    var alloc: std.mem.Allocator = undefined;
    fn reset(a: std.mem.Allocator) void {
        alloc = a;
        log = .empty;
    }
    fn effects() Effects {
        return .{ .enterAp = enter, .leaveAp = leave, .persistState = persist, .announceMdns = announce };
    }
    fn enter(_: ?*anyopaque) void {
        log.append(alloc, 'A') catch unreachable;
    }
    fn leave(_: ?*anyopaque) void {
        log.append(alloc, 'a') catch unreachable;
    }
    fn persist(_: ?*anyopaque, s: State) void {
        log.append(alloc, "fgd"[@intFromEnum(s)]) catch unreachable;
    }
    fn announce(_: ?*anyopaque, _: State) void {
        log.append(alloc, 'm') catch unreachable;
    }
};

const wifi_connecting_payload =
    \\{"type":"network.wifi.state","id":1,"ts":0,"data":{"state":"connecting","connected_ssid":null}}
;
const wifi_connected_payload =
    \\{"type":"network.wifi.state","id":2,"ts":0,"data":{"state":"connected","connected_ssid":"net"}}
;
const wifi_disconnected_payload =
    \\{"type":"network.wifi.state","id":3,"ts":0,"data":{"state":"disconnected","connected_ssid":null}}
;

test "Manager scenario: factory boot, no config, no carrier -> provisioning + AP" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-a");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};

    MTrace.reset(a);
    defer MTrace.log.deinit(MTrace.alloc);
    var m = try Manager.init(a, &st, .{ .machine_id = "e5c1770f9f03a1" });
    defer m.deinit();
    m.probe_fn = TestProbe.probe;
    TestProbe.current = .{};
    m.machine.effects = MTrace.effects();

    _ = m.process(.startup);
    try std.testing.expectEqual(State.provisioning, m.currentState());
    try std.testing.expect(m.apActive());
    try std.testing.expectEqualStrings("Agm", MTrace.log.items);
}

test "Manager scenario: wired lease + wired_provisions -> provisioned at startup" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-b");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};
    st.config.api.wired_provisions = true;

    MTrace.reset(a);
    defer MTrace.log.deinit(MTrace.alloc);
    var m = try Manager.init(a, &st, .{ .machine_id = "e5c1770f9f03a1" });
    defer m.deinit();
    m.probe_fn = TestProbe.probe;
    TestProbe.current = .{ .eth_carrier = true, .eth_lease = true, .has_addr = true, .default_route = true };
    m.machine.effects = MTrace.effects();

    _ = m.process(.startup);
    try std.testing.expectEqual(State.provisioned, m.currentState());
    try std.testing.expect(!m.apActive());
    try std.testing.expectEqualStrings("dm", MTrace.log.items);
}

test "Manager scenario: wifi config at boot -> station attempt -> verified -> provisioned" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-c");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};
    st.config.network.wifi.connection = .{ .ssid = "net", .psk = "password1" };

    MTrace.reset(a);
    defer MTrace.log.deinit(MTrace.alloc);
    var m = try Manager.init(a, &st, .{ .machine_id = "e5c1770f9f03a1" });
    defer m.deinit();
    m.probe_fn = TestProbe.probe;
    TestProbe.current = .{};
    m.machine.effects = MTrace.effects();

    // Pre-baked config: no provisioning detour, no AP (docs/07 §4
    // direct factory → provisioned edge).
    _ = m.process(.startup);
    try std.testing.expectEqual(State.factory, m.currentState());
    try std.testing.expect(!m.apActive());
    try std.testing.expectEqualStrings("", MTrace.log.items);

    // iwd walks connecting → connected (bus events); no effects yet.
    m.handleBusEvent("network.wifi.state", wifi_connecting_payload);
    m.drainPending();
    m.handleBusEvent("network.wifi.state", wifi_connected_payload);
    m.drainPending();
    try std.testing.expectEqual(State.factory, m.currentState());
    try std.testing.expectEqualStrings("", MTrace.log.items);

    // Address + default route land → the next observation promotes.
    TestProbe.current = .{ .has_addr = true, .default_route = true };
    m.pokeObserve();
    m.drainPending();
    try std.testing.expectEqual(State.provisioned, m.currentState());
    try std.testing.expectEqualStrings("dm", MTrace.log.items);
}

test "Manager scenario: portal connect failure -> AP returns (wrong-password loop)" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-d");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};

    MTrace.reset(a);
    defer MTrace.log.deinit(MTrace.alloc);
    var m = try Manager.init(a, &st, .{ .machine_id = "e5c1770f9f03a1" });
    defer m.deinit();
    m.probe_fn = TestProbe.probe;
    TestProbe.current = .{};
    m.machine.effects = MTrace.effects();

    // Boot into the portal.
    _ = m.process(.startup);
    try std.testing.expect(m.apActive());

    // PUT wifi/connection accepted → the single-radio flip (AP down).
    m.notifyWifiConnectStarted();
    m.drainPending();
    try std.testing.expect(!m.apActive());

    // iwd reports the attempt dead → AP comes back for another try.
    m.handleBusEvent("network.wifi.state", wifi_disconnected_payload);
    m.drainPending();
    try std.testing.expect(m.apActive());
    try std.testing.expectEqual(State.provisioning, m.currentState());
    try std.testing.expectEqualStrings("Agm" ++ "a" ++ "A", MTrace.log.items);
}

test "Manager default effects: store persistence + system.provisioned event" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-e");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};
    st.config.api.wired_provisions = true;

    var bus = events_mod.EventBus.init(a);
    defer bus.deinit();
    const sub = try bus.subscribe(null);
    defer sub.cancel();

    var m = try Manager.init(a, &st, .{ .machine_id = "e5c1770f9f03a1", .event_bus = &bus });
    defer m.deinit();
    m.probe_fn = TestProbe.probe;
    TestProbe.current = .{ .eth_carrier = true, .eth_lease = true, .has_addr = true, .default_route = true };

    _ = m.process(.startup);
    try std.testing.expectEqual(State.provisioned, m.currentState());

    // Persisted atomically to the store document…
    const doc = try fsutil.readFileAlloc(a, path, 64 * 1024);
    defer a.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"provisioning\": \"provisioned\"") != null);

    // …and narrated on the event ring.
    const ev = (try sub.next(0)).?;
    try std.testing.expectEqualStrings(events_mod.types.system_provisioned, ev.event_type);
    try std.testing.expect(std.mem.indexOf(u8, ev.payload, "\"state\":\"provisioned\"") != null);
}

test "Manager: initial state from the store; corrupt strings default factory" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-f");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();

    st.config.system.provisioning = "provisioned";
    var m1 = try Manager.init(a, &st, .{});
    defer m1.deinit();
    try std.testing.expectEqual(State.provisioned, m1.currentState());

    st.config.system.provisioning = "half-baked";
    var m2 = try Manager.init(a, &st, .{});
    defer m2.deinit();
    try std.testing.expectEqual(State.factory, m2.currentState());
}

test "Manager: wired availability + AP override observation assembly" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-g");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};

    MTrace.reset(a);
    defer MTrace.log.deinit(MTrace.alloc);
    var m = try Manager.init(a, &st, .{ .machine_id = "e5c1770f9f03a1" });
    defer m.deinit();
    m.probe_fn = TestProbe.probe;
    m.machine.effects = MTrace.effects();

    // enabled_override=false suppresses the AP even while unprovisioned.
    st.config.system.ap.enabled_override = false;
    TestProbe.current = .{};
    _ = m.process(.startup);
    try std.testing.expectEqual(State.provisioning, m.currentState());
    try std.testing.expect(!m.apActive());

    // Wired lease without promotion policy: marker only.
    TestProbe.current = .{ .eth_carrier = true, .eth_lease = true, .has_addr = true };
    _ = m.process(.observe);
    try std.testing.expect(m.wiredAvailable());
    try std.testing.expectEqual(State.provisioning, m.currentState());
}

test "Manager: forced override brings the AP up despite carrier; flipConnect round-trip" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-j");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};

    MTrace.reset(a);
    defer MTrace.log.deinit(MTrace.alloc);
    var m = try Manager.init(a, &st, .{ .machine_id = "e5c1770f9f03a1" });
    defer m.deinit();
    m.probe_fn = TestProbe.probe;
    m.machine.effects = MTrace.effects();

    // eth carrier present: the auto-trigger cannot fire (docs/07 §4),
    // so startup lands in provisioning with the AP down…
    TestProbe.current = .{ .eth_carrier = true, .eth_lease = true };
    _ = m.process(.startup);
    try std.testing.expectEqual(State.provisioning, m.currentState());
    try std.testing.expect(!m.apActive());

    // …until PUT /network/wifi/ap {"enabled": true} forces it (the e2e
    // rig's `astroctl wifi ap enable` path).
    try st.setApEnabledOverride(true);
    _ = m.process(.observe);
    try std.testing.expect(m.apActive());

    // Clearing the override with carrier present tears it down again.
    try st.setApEnabledOverride(null);
    _ = m.process(.observe);
    try std.testing.expect(!m.apActive());

    // flipConnect with no wifi backend: leave (if up) → attempt fails →
    // failed feeds back; with carrier present the AP stays down.
    try st.setApEnabledOverride(true);
    _ = m.process(.observe);
    try std.testing.expect(m.apActive());
    try st.setApEnabledOverride(null);
    m.flipConnect("net", "password1");
    try std.testing.expect(!m.apActive());
    try std.testing.expectEqual(State.provisioning, m.currentState());
    // Effect trace: startup persist ('g','m'), then enter/leave cycles.
    try std.testing.expectEqualStrings("gm" ++ "A" ++ "a" ++ "A" ++ "a", MTrace.log.items);
}

test "Manager: static ethernet config counts as network config" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-h");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};

    var m = try Manager.init(a, &st, .{});
    defer m.deinit();
    try std.testing.expect(!m.hasNetworkConfig());

    var map: std.json.ArrayHashMap(store_mod.Config.Ethernet) = .{};
    defer map.map.deinit(a);
    try map.map.put(a, "eth0", .{ .ipv4 = .{ .mode = "static", .address = "10.0.0.2", .prefix = 24 } });
    st.config.network.ethernet = map;
    try std.testing.expect(m.hasNetworkConfig());

    // DHCP-only entries do not count (the wired path owns plain DHCP).
    map.map.getPtr("eth0").?.ipv4.mode = "dhcp";
    try std.testing.expect(!m.hasNetworkConfig());
}

test "Manager live start/stop smoke (threads, degraded sources tolerated)" {
    // The live startup step legitimately warns (no wifi backend in unit
    // tests); keep the gate output clean.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = fsutil.testTmpPath(&pbuf, "prov-i");
    var st = try store_mod.Store.load(a, path);
    defer st.deinit();
    defer fsutil.unlink(path) catch {};

    var bus = events_mod.EventBus.init(a);
    defer bus.deinit();

    var m = try Manager.init(a, &st, .{ .machine_id = "e5c1770f9f03a1", .event_bus = &bus });
    defer m.deinit();
    m.start();
    // Nudge both the queue path and the observe path once.
    m.pokeObserve();
    _ = bus.publishEnvelope(events_mod.types.network_ethernet_state, null, "{\"iface\":\"eth0\",\"bound\":true}") catch 0;
    m.stop();
    // Whatever the live probe saw, the machine holds a valid state.
    _ = m.currentState();
}
