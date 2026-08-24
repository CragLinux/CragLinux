#!/bin/sh
#
# Mount the bootenv partition (vfat) at /run/crag/bootenv so userspace
# can reach the bootloader environment as files: uboot.env (libubootenv
# via /etc/fw_env.config) or grubenv (RAUC grub backend + grub-editenv).
# See the bootenv-mount service file for context. rw because mark-good
# and RAUC's post-install slot flip both write it.

DINIT_SERVICE=bootenv-mount

. /usr/lib/dinit.d/early/scripts/common.sh

[ -n "$DINIT_CONTAINER" ] && exit 0

bootenv_dev=$(findfs PARTLABEL=bootenv 2>/dev/null) || bootenv_dev=
if [ -z "$bootenv_dev" ]; then
    log_debug "no PARTLABEL=bootenv (direct boot?), skipping"
    exit 0
fi

mkdir -p /run/crag/bootenv
if ! mountpoint -q /run/crag/bootenv; then
    # fmask/dmask: env contents are not secrets, but nothing unprivileged
    # has business writing the bootloader env
    mount -t vfat -o rw,noatime,fmask=0177,dmask=0077 \
        "$bootenv_dev" /run/crag/bootenv || exit 1
fi

exit 0
