# shellcheck shell=sh
# shellcheck disable=SC2154  # $reason/$interface/$new_* are assigned by
#                            # dhcpcd-run-hooks(8) before sourcing us
# Astro dhcpcd lease-export hook (docs/07 §2 DNS flow; M3 phase 3).
#
# SOURCED (not executed) by dhcpcd-run-hooks for every state transition,
# as root — dhcpcd's hook mechanism sources every file in @HOOKDIR@/*
# (dhcpcd-10.3.2 hooks/dhcpcd-run-hooks.in:338; HOOKDIR is
# ${LIBEXECDIR}/dhcpcd-hooks per Makefile.inc:24 and the port passes
# --libexecdir=/usr/lib, so /usr/lib/dhcpcd-hooks). Wired in via the
# 60-astro-lease symlink next to the packaged hooks.
# Runtime variables ($reason, $interface, $new_*) are dhcpcd-run-hooks(8);
# $new_subnet_cidr is the v4 prefix length (src/dhcp.c writes
# %s_subnet_cidr), $new_routers is a space-separated router list.
#
# Job: mirror per-interface lease facts into /run/astro/net/leases/
# <iface>.json so unprivileged astrod (which cannot be a dhcpcd hook —
# hooks run as root) can consume them. astrod inotify-watches the
# directory (netconf.zig LeaseWatcher), re-renders /run/astro/resolv.conf
# from store DNS + these files, and updates observed state. Both dhcpcd
# configs say 'nohook resolv.conf', so this export is the ONLY path
# DHCP-learned DNS takes into the system (one resolv.conf writer).
#
# Document shape (netconf.zig parseLease; unknown fields tolerated):
#   {"iface", "reason", "address", "prefix", "gateway", "dns": [],
#    "domain", "ts"}
# v1 limitation: one file per interface, so the LAST transition wins —
# a BOUND6 following a BOUND replaces the v4 facts with the v6 facts
# (both name-server variable sets are merged below to soften this).
#
# The lease dir is root-writable/astrod-readable by design
# (tmpfiles.d/astrod.conf: d /run/astro/net/leases 0755 root astrod).
# Writes are atomic (tmp + mv) so the watcher never reads a torn file.

astro_lease_dir=/run/astro/net/leases

# JSON string escaping for the daemon-supplied values (IPs/domains are
# tame, but a hostile DHCP server controls $new_domain_name).
astro_json_escape()
{
	printf %s "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

astro_write_lease()
{
	astro_tmp="${astro_lease_dir}/.${interface}.tmp"
	astro_dns_json=""
	# v4 and v6(DHCPv6) resolver lists; only one is set per reason.
	for astro_ns in ${new_domain_name_servers:-} ${new_dhcp6_name_servers:-}; do
		astro_dns_json="${astro_dns_json:+${astro_dns_json}, }\"$(astro_json_escape "$astro_ns")\""
	done
	astro_domain="${new_domain_name:-${new_dhcp6_domain_search:-}}"
	# First router only: the WAN brain (astrod) wants THE gateway.
	astro_gateway="${new_routers:-}"
	astro_gateway="${astro_gateway%% *}"
	{
		printf '{"iface": "%s", "reason": "%s", "dns": [%s]' \
			"$(astro_json_escape "$interface")" \
			"$(astro_json_escape "$reason")" \
			"$astro_dns_json"
		[ -n "$astro_domain" ] &&
			printf ', "domain": "%s"' "$(astro_json_escape "$astro_domain")"
		[ -n "${new_ip_address:-}" ] &&
			printf ', "address": "%s"' "$(astro_json_escape "$new_ip_address")"
		case "${new_subnet_cidr:-}" in
		''|*[!0-9]*) ;; # absent or non-numeric: omit
		*)	printf ', "prefix": %s' "$new_subnet_cidr" ;;
		esac
		[ -n "$astro_gateway" ] &&
			printf ', "gateway": "%s"' "$(astro_json_escape "$astro_gateway")"
		printf ', "ts": %s}\n' "$(date +%s)"
	} > "$astro_tmp" && mv "$astro_tmp" "${astro_lease_dir}/${interface}.json"
}

if [ -d "$astro_lease_dir" ]; then
	case "$reason" in
	BOUND|RENEW|REBIND|REBOOT|INFORM|STATIC|BOUND6|RENEW6|REBIND6|INFORM6)
		astro_write_lease
		;;
	EXPIRE|EXPIRE6|RELEASE|RELEASE6|STOP|STOPPED|NOCARRIER|DEPARTED)
		rm -f "${astro_lease_dir}/${interface}.json"
		;;
	esac
fi
