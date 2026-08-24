#!/bin/sh
#
# Crag AP captive-portal redirect — UP half (docs/07 §4 item 3, M3
# phase 4). Root oneshot (dinit service crag-portal-redirect-start,
# dispatched on demand by cragd around AP bring-up — the docs/02 §7
# residual-root-ops pattern; cragd itself is capless and cannot own
# ports <1024 or netfilter).
#
# Installs an nft NAT table that, ON THE AP INTERFACE ONLY, rewrites the
# privileged ports phones actually probe to cragd's unprivileged ones:
#   tcp :80  -> :8080  (the portal HTTP listener on 192.168.223.1)
#   udp :53  -> :5354  (cragd's DNS catch-all; NOT 5353 — that is mDNS)
#
# The AP interface is wlan0 by v1 policy (the first iwd device
# alphabetically — the baked phase-4 decision; CRAG_AP_IF exists for
# tests and future multi-radio boards).
#
# Idempotent: the declare-delete-recreate preamble makes a re-run
# replace the table instead of stacking duplicate rules.
#
# Kernel side: boards/common/kernel/crag-net.fragment carries the
# NFT_*/NF_* symbols this exact ruleset needs (cited rule-by-rule there).

AP_IF="${CRAG_AP_IF:-wlan0}"

exec /usr/bin/nft -f - << EOF
table ip crag_portal
delete table ip crag_portal
table ip crag_portal {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "${AP_IF}" tcp dport 80 redirect to :8080
        iifname "${AP_IF}" udp dport 53 redirect to :5354
    }
}
EOF
