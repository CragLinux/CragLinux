#!/bin/sh
#
# Boot-success watchdog (docs/05 §4; see the crag-boot-watchdog service
# file). The scripted service start detaches a watcher (setsid) and
# returns immediately; the watcher polls for the boot-success milestone
# and, if it is not reached within the timeout, forces a reboot so the
# bootloader's attempt counters advance and slot fallback can happen
# (AD-008/AD-009: 3 attempts, then the other slot). The watcher exits
# quietly once boot-success is up.

# Not an A/B boot -> nothing to guard
grep -q 'rauc\.slot=' /proc/cmdline || exit 0

TIMEOUT=300
if [ -r /data/.crag/boot-watchdog-timeout ]; then
    read -r t < /data/.crag/boot-watchdog-timeout 2>/dev/null || t=
    case "$t" in
        ''|*[!0-9]*) ;;  # ignore garbage
        *) TIMEOUT=$t ;;
    esac
fi

setsid sh -c '
    waited=0
    while [ "$waited" -lt "'"$TIMEOUT"'" ]; do
        if dinitctl is-started boot-success >/dev/null 2>&1; then
            exit 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    echo "crag-boot-watchdog: boot-success not reached in '"$TIMEOUT"'s, forcing reboot" > /dev/console 2>/dev/null || :
    sync
    reboot
    sleep 30
    reboot -f
' </dev/null >/dev/null 2>&1 &

exit 0
