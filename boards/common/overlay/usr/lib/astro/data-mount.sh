#!/bin/sh
#
# Astro data-mount early service (docs/02 §4, AD-005; docs/02 §5.1 graph
# node "data.mount"): mounts the shared mutable-state partition
# (PARTLABEL=data, ext4) on /data and wires every mutable path of the
# read-only rootfs into it:
#
#   /etc              overlayfs, upper=/data/overlay/etc
#   /var/log          bind of /data/var/log
#   /var/lib/seedrng  bind of /data/keys/seedrng (early-rng seed state)
#   /tmp /var/tmp     tmpfs (size-capped)
#   /var/cache        tmpfs
#
# Ordering: runs from the dinit-chimera early graph — early-fs-local.target
# (shadowed in /etc/dinit.d) waits-for data-mount, and early-rng /
# early-machine-id run only after early-fs-local.target, so the seed dir
# and the writable /etc are in place before they start.
#
# Direct-boot developer images have no data partition: the tmpfs mounts
# still happen, everything /data-backed is skipped, exit 0 (a dev rootfs
# is rw ext4 and needs none of it). Growing /data to fill the disk on
# first boot is astrod/firstboot work (M2) — not done here.

DINIT_SERVICE=data-mount

. /usr/lib/dinit.d/early/scripts/common.sh

# Containers get no disks and no tmpfs games
[ -n "$DINIT_CONTAINER" ] && exit 0

umask 022

# tmpfs pieces first — wanted on RO roots regardless of /data presence
# (harmless on rw dev roots; sizes deliberately capped, docs/02 §4.2)
if ! mountpoint -q /tmp; then
    mount -t tmpfs -o nodev,nosuid,mode=1777,size=25% tmpfs /tmp || :
fi
if ! mountpoint -q /var/tmp; then
    mount -t tmpfs -o nodev,nosuid,mode=1777,size=10% tmpfs /var/tmp || :
fi
if ! mountpoint -q /var/cache; then
    mount -t tmpfs -o nodev,nosuid,mode=0755,size=10% tmpfs /var/cache || :
fi

# The A/B image carries PARTLABEL=data (AD-007 partition 7). Absent means
# a direct-boot developer disk — nothing more to do.
data_dev=$(findfs PARTLABEL=data 2>/dev/null) || data_dev=
if [ -z "$data_dev" ]; then
    log_debug "no PARTLABEL=data (direct boot?), skipping /data"
    exit 0
fi

if ! mountpoint -q /data; then
    mount -t ext4 -o noatime "$data_dev" /data || exit 1
fi

# Ensure the AD-005 §4.1 skeleton exists (survives a factory-reset wipe)
mkdir -p /data/config \
         /data/overlay/etc /data/overlay/.etc-work \
         /data/var/log \
         /data/apps \
         /data/keys/seedrng \
         /data/.astro

# /etc overlay (docs/02 §4.3): upper/work in /data, RO rootfs /etc as lower
if ! mountpoint -q /etc; then
    mount -t overlay \
        -o lowerdir=/etc,upperdir=/data/overlay/etc,workdir=/data/overlay/.etc-work \
        etc-overlay /etc || exit 1
fi

# Persistent logs + rng seed state
if ! mountpoint -q /var/log; then
    mount -o bind /data/var/log /var/log || exit 1
fi
if ! mountpoint -q /var/lib/seedrng; then
    mount -o bind /data/keys/seedrng /var/lib/seedrng || exit 1
fi

exit 0
