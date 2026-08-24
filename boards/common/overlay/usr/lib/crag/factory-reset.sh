#!/bin/sh
#
# Crag factory reset — the ROOT half of POST /system/factory-reset
# (docs/07 §5, M3 phase 4). Dispatched as the crag-factory-reset dinit
# oneshot by cragd (docs/02 §7 residual-root-ops: the daemon is capless
# and cannot write root-owned /data/.crag or reboot by itself — it has
# already verified the confirm-with-machine-id body before dispatching).
#
# Semantics: leave the flag, make it durable, reboot. The WIPE happens
# on the way back up — data-mount.sh's factory-reset executor runs right
# after mounting /data, before anything reads it — so no service on the
# running system ever observes a half-wiped /data. After the wipe,
# firstboot reruns by construction (its done-stamp was on /data) and the
# provisioning state returns to factory. Slots are untouched: the device
# keeps its current firmware (docs/07 §5).

# Direct-boot dev disks have no /data — nothing to reset. Failing the
# oneshot (visible in dinitctl) beats pretending a reset happened.
mountpoint -q /data || { echo "factory-reset: /data is not a mountpoint" >&2; exit 1; }

# data-mount guarantees the skeleton, but the flag is the whole job —
# do not let a missing directory turn a reset into a silent no-op.
mkdir -p /data/.crag
: > /data/.crag/factory-reset-request
sync

# /usr/bin/reboot IS dinit's shutdown client on this image
# (MIGRATION-NOTES §15) — clean teardown, then the executor wipes.
exec reboot
