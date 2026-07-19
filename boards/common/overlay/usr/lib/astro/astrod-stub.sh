#!/bin/sh
#
# astrod M1 stub (docs/11 M1: "astrod stubbed as a health-check
# placeholder"; the real Zig daemon lands at M3). A scripted dinit
# service: runs the platform health check that defines "this boot is
# good" at M1 scope and exits 0, which drives the boot-success milestone
# (docs/02 §5.1). When real astrod replaces this, its own readiness +
# health check takes over the same graph position.
#
# Healthy at M1 means:
#   - when the disk carries a data partition (A/B image): /data is
#     mounted and the /etc overlay is active (AD-005 mutable state up)
#   - direct-boot dev disks (no data partition): nothing to assert
#
# Exit nonzero -> astrod [FAILED] -> boot-success never reached ->
# (from M2) rauc-mark-good never runs and the bootloader's attempt
# counters eventually fall back to the other slot.

DINIT_SERVICE=astrod

. /usr/lib/dinit.d/early/scripts/common.sh

data_dev=$(findfs PARTLABEL=data 2>/dev/null) || data_dev=
if [ -z "$data_dev" ]; then
    log_debug "no data partition (direct boot?), health check trivially OK"
    exit 0
fi

if ! mountpoint -q /data; then
    echo "astrod: health check failed: /data is not mounted" >&2
    exit 1
fi

if ! awk '$2 == "/etc" && $3 == "overlay" { found = 1 } END { exit !found }' /proc/mounts; then
    echo "astrod: health check failed: /etc overlay is not active" >&2
    exit 1
fi

exit 0
