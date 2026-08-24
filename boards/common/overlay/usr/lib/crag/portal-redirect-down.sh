#!/bin/sh
#
# Crag AP captive-portal redirect — DOWN half (see portal-redirect-up.sh
# for the whole story). Root oneshot (dinit service
# crag-portal-redirect-stop, dispatched by cragd after the AP goes
# down). Removes the redirect table; idempotent — succeeding when the
# table is already gone matters because cragd fires this on every
# AP-down edge, including error paths where the up half never ran.

if /usr/bin/nft list table ip crag_portal > /dev/null 2>&1; then
    exec /usr/bin/nft delete table ip crag_portal
fi
exit 0
