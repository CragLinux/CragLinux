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
# is rw ext4 and needs none of it).
#
# Growth (docs/02 §4, M1 "grown+mounted"): the flashed image is sized
# minimally; on a larger disk/card all slack belongs to /data (the last
# partition, AD-007). Before mounting, if the disk has more than ~1 MiB
# of slack past the data partition, the GPT entry is grown with sfdisk
# (which also relocates the backup GPT header to the true end of the
# disk), the kernel view is updated with resizepart, and the ext4 is
# grown with resize2fs. Idempotent: a re-boot with no slack is a no-op.

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

# --- grow to fill the disk (before fsck/mount; see header) ---------------
grow_data() {
    # all sizes below are 512-byte sectors, as /sys reports them
    _pname=${data_dev##*/}
    _pdir=/sys/class/block/$_pname
    # not a partition (e.g. a whole-disk or loop /data on odd dev setups)
    [ -r "$_pdir/partition" ] || return 0
    _partno=$(cat "$_pdir/partition")
    _diskdir=$(readlink -f "$_pdir")
    _diskdir=${_diskdir%/*}
    _disk=/dev/${_diskdir##*/}
    [ -b "$_disk" ] || return 0
    _dsize=$(cat "$_diskdir/size")
    _pstart=$(cat "$_pdir/start")
    _psize=$(cat "$_pdir/size")
    # 33 sectors of backup GPT live at the disk end; only act on real slack
    _slack=$((_dsize - _pstart - _psize - 33))
    [ "$_slack" -gt 2048 ] || return 0

    # to the console: rare + significant, and the boot-smoke stage asserts
    # on this line (dinit does not forward early-script stdout to serial)
    echo "data-mount: growing $data_dev by ${_slack} sectors to fill $_disk" > /dev/console 2>/dev/null || \
        echo "data-mount: growing $data_dev by ${_slack} sectors to fill $_disk"
    # ', +' = keep start, extend to maximum; --force because the disk
    # carries the mounted root and (on a reflashed larger disk) a
    # misplaced backup GPT header, both of which sfdisk would refuse
    if ! printf ', +\n' | sfdisk -q --force --no-reread -N "$_partno" "$_disk"; then
        echo "data-mount: sfdisk grow failed, keeping current size" >&2
        return 0
    fi
    # tell the kernel (rereadpt would fail: root is on this disk), then
    # grow the fs to the actual new GPT size
    _newsize=$(sfdisk -q --dump "$_disk" | \
        sed -n "s|^${data_dev}[[:space:]]*:.*size=[[:space:]]*\([0-9]*\).*|\1|p")
    if [ -n "$_newsize" ] && [ "$_newsize" -gt "$_psize" ]; then
        resizepart "$_disk" "$_partno" "$_newsize" || :
        e2fsck -f -p "$data_dev" >/dev/null 2>&1 || :
        resize2fs "$data_dev" >/dev/null 2>&1 || \
            echo "data-mount: resize2fs failed, /data stays at its current size" >&2
    fi
}

if ! mountpoint -q /data; then
    grow_data
    mount -t ext4 -o noatime "$data_dev" /data || exit 1
fi

# --- factory reset executor (docs/07 §5, M3 phase 4) ---------------------
# The flag is left by the astro-factory-reset oneshot (API path: astrod
# verifies {"confirm": "<machine-id>"} then dispatches it, syncs,
# reboots) or by a board's reset-button hook. Running HERE — right after
# the mount, before any other service reads /data — is the docs/07 §5
# "early dinit oneshot, before anything reads /data" requirement: no
# process on this boot ever observes a half-wiped tree. Fast path only
# (rm -rf of the contents, lost+found kept); the blkdiscard + re-mkfs
# secure path is a DEFERRED per-product option (docs/07 §5) — recorded,
# not implemented. Boot then continues on the fresh /data: the skeleton
# below is recreated and firstboot reruns by construction (its
# done-stamp lived on /data). Slots are untouched.
if [ -e /data/.astro/factory-reset-request ]; then
    # To the console: rare + significant (same convention as grow_data).
    echo "data-mount: factory-reset flag found, wiping /data" > /dev/console 2>/dev/null || \
        echo "data-mount: factory-reset flag found, wiping /data"
    for _entry in /data/* /data/.[!.]* /data/..?*; do
        # Unmatched globs stay literal; -L catches dangling symlinks.
        [ -e "$_entry" ] || [ -L "$_entry" ] || continue
        case "$_entry" in /data/lost+found) continue ;; esac
        rm -rf "$_entry"
    done
    sync
fi

# Ensure the AD-005 §4.1 skeleton exists (survives a factory-reset wipe)
mkdir -p /data/config \
         /data/overlay/etc /data/overlay/.etc-work \
         /data/var/log \
         /data/apps \
         /data/keys/seedrng \
         /data/.astro

# App data dirs (docs/08 §5): each app service that declared data_dir=true
# gets /data/apps/<name> owned by its service user. The list is baked at
# image assembly (40-service-manifests.sh -> /etc/astro/app-data-dirs);
# replay it now that /data is mounted (survives a factory-reset wipe). The
# record file lives in the RO rootfs /etc lower and the app users are in the
# baked /etc/passwd, so both the file and the chown-by-name resolve here even
# though the /etc overlay is not mounted until below.
if [ -f /etc/astro/app-data-dirs ]; then
    while read -r _app _owner; do
        [ -n "$_app" ] || continue
        case "$_app" in \#*) continue ;; esac
        mkdir -p "/data/apps/$_app"
        chown "${_owner:-root}:${_owner:-root}" "/data/apps/$_app" 2>/dev/null || :
    done < /etc/astro/app-data-dirs
fi

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
