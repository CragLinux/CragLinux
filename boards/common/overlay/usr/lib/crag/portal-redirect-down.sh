#!/bin/sh
#
# Astro AP captive-portal redirect — DOWN half (see portal-redirect-up.sh
# for the whole story). Root oneshot (dinit service
# astro-portal-redirect-stop, dispatched by astrod after the AP goes
# down). Removes the redirect table; idempotent — succeeding when the
# table is already gone matters because astrod fires this on every
# AP-down edge, including error paths where the up half never ran.

if /usr/bin/nft list table ip astro_portal > /dev/null 2>&1; then
    exec /usr/bin/nft delete table ip astro_portal
fi
exit 0
