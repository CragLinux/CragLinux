#!/bin/bash
set -euo pipefail

# astro deploy — the AD-026 developer sideload loop (docs/08 §6).
#
# Push a rebuilt app to a RUNNING dev-variant device and restart its
# service in seconds. Three modes, fastest first:
#
#   binary  (default)  copy one built artifact over the service's
#                      command path, restart, stream the log.
#                      Round-trip target: < 5 s on QEMU.
#   package (--pkg)    push a cbuild-built .apk, apk add it on the
#                      device (dev variant: full apk, rw rootfs),
#                      restart. Slower, exercises real packaging.
#   watch   (--watch)  re-run the deploy whenever the artifact
#                      changes — edit-compile-run loops.
#
# PROD IS SEALED BY DESIGN (AD-004/AD-026): prod images are read-only
# squashfs with no ssh — there is no sideload path to them. This tool
# additionally refuses any target whose rootfs is not writable.
#
# Usage:
#   sdk/astro-deploy.sh <service> --binary <path> [options]
#   sdk/astro-deploy.sh <service> --pkg <path.apk> [options]
# Options:
#   --to qemu | --to host[:port]   target (default qemu = 127.0.0.1:2222,
#                                  run-qemu.sh --ssh-port=2222)
#   --key <ssh-key>                identity (default keys/dev/ssh-test)
#   --watch                        redeploy on artifact change
#   --no-log                       skip log streaming after restart
#
# Works from an Astro checkout or an external-tree checkout next to
# one; the SDK tarball ships it alongside the toolchain. Binary-mode
# drift is recorded on-device in /etc/astro/deploy-drift so `apk
# query`-based fleet introspection can see locally-modified packages
# (docs/08 §6).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SERVICE="${1:?Usage: $0 <service> --binary <path> | --pkg <path.apk> [--to qemu|host[:port]] [--watch] [--no-log]}"
shift

TARGET="qemu"
BINARY=""
PKG=""
WATCH=false
STREAM_LOG=true
SSH_KEY="${PROJECT_ROOT}/keys/dev/ssh-test"
for arg in "$@"; do
    case "$arg" in
        --to=*)     TARGET="${arg#--to=}" ;;
        --to)       : ;;  # space form handled below
        --binary=*) BINARY="${arg#--binary=}" ;;
        --pkg=*)    PKG="${arg#--pkg=}" ;;
        --key=*)    SSH_KEY="${arg#--key=}" ;;
        --watch)    WATCH=true ;;
        --no-log)   STREAM_LOG=false ;;
        *)
            # space-separated value forms (--to qemu, --binary x, ...)
            if   [ "${prev:-}" = "--to" ];     then TARGET="$arg"
            elif [ "${prev:-}" = "--binary" ]; then BINARY="$arg"
            elif [ "${prev:-}" = "--pkg" ];    then PKG="$arg"
            elif [ "${prev:-}" = "--key" ];    then SSH_KEY="$arg"
            elif [ "$arg" != "--to" ] && [ "$arg" != "--binary" ] && \
                 [ "$arg" != "--pkg" ] && [ "$arg" != "--key" ]; then
                echo "ERROR: unknown option: $arg" >&2; exit 1
            fi
            ;;
    esac
    prev="$arg"
done

[ -n "$BINARY" ] || [ -n "$PKG" ] || {
    echo "ERROR: one of --binary <path> or --pkg <path.apk> is required" >&2
    exit 1
}
[ -z "$BINARY" ] || [ -f "$BINARY" ] || { echo "ERROR: no such artifact: $BINARY" >&2; exit 1; }
[ -z "$PKG" ] || [ -f "$PKG" ] || { echo "ERROR: no such apk: $PKG" >&2; exit 1; }
[ -f "$SSH_KEY" ] || { echo "ERROR: ssh key not found: $SSH_KEY (dev images trust keys/dev/ssh-test)" >&2; exit 1; }

case "$TARGET" in
    qemu) HOST="127.0.0.1"; PORT="2222" ;;
    *:*)  HOST="${TARGET%%:*}"; PORT="${TARGET##*:}" ;;
    *)    HOST="$TARGET"; PORT="22" ;;
esac

SSH=(ssh -i "$SSH_KEY" -p "$PORT" -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=5 "root@${HOST}")
SCP=(scp -i "$SSH_KEY" -P "$PORT" -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

say() { echo "[astro-deploy] $*"; }

##############################################################################
# One deploy round
##############################################################################
deploy_once() {
    local t0 t1
    t0=$(date +%s%N)

    # Reachability + THE PROD GUARD: no writable rootfs, no sideload.
    "${SSH[@]}" true 2>/dev/null || {
        say "ERROR: cannot reach root@${HOST}:${PORT} — is the dev VM up? (run-qemu.sh <board> dev --image --ssh-port=${PORT})"
        return 1
    }
    if ! "${SSH[@]}" "test -w /usr/bin" 2>/dev/null; then
        say "ERROR: target rootfs is read-only — prod images never accept sideloads (AD-004/AD-026)"
        return 1
    fi

    if [ -n "$PKG" ]; then
        deploy_pkg || return 1
    else
        deploy_binary || return 1
    fi

    "${SSH[@]}" "dinitctl restart ${SERVICE}" || {
        say "ERROR: dinitctl restart ${SERVICE} failed"
        return 1
    }
    t1=$(date +%s%N)
    say "deployed + restarted ${SERVICE} in $(( (t1 - t0) / 1000000 )) ms"
    return 0
}

deploy_binary() {
    # The install path comes from the service description's command=
    # line (the artifact a restart actually re-executes). etc wins over
    # usr/lib, mirroring dinit's own lookup order.
    # (One file only: the device's awk exits on a missing first file
    # rather than continuing, so pick the existing description first.)
    local dest
    dest=$("${SSH[@]}" "f=/etc/dinit.d/${SERVICE}; [ -f \"\$f\" ] || f=/usr/lib/dinit.d/${SERVICE}; \
        awk -F' *= *' '\$1==\"command\"{print \$2; exit}' \"\$f\" 2>/dev/null" | awk '{print $1}')
    [ -n "$dest" ] || {
        say "ERROR: no service description with a command= line for '${SERVICE}' on the device"
        return 1
    }

    say "binary ${BINARY} -> ${dest}"
    "${SCP[@]}" "$BINARY" "root@${HOST}:/tmp/.astro-deploy.$$" >/dev/null

    # rename-then-replace: renaming a running binary is legal (the old
    # inode lives on); overwriting it in place would be ETXTBSY.
    "${SSH[@]}" "set -e
        mv '${dest}' '${dest}.deploy-old' 2>/dev/null || :
        install -m 0755 /tmp/.astro-deploy.$$ '${dest}'
        rm -f /tmp/.astro-deploy.$$ '${dest}.deploy-old'
        mkdir -p /etc/astro
        grep -qxF 'binary ${dest} (${SERVICE})' /etc/astro/deploy-drift 2>/dev/null \
            || echo 'binary ${dest} (${SERVICE})' >> /etc/astro/deploy-drift"
    say "drift recorded on device (/etc/astro/deploy-drift): ${dest} is locally modified"
}

deploy_pkg() {
    local base
    base=$(basename "$PKG")
    say "package ${base} -> apk add"
    "${SCP[@]}" "$PKG" "root@${HOST}:/tmp/${base}" >/dev/null

    # The image's baked /etc/apk/keys may predate the CURRENT cbuild
    # signing key (cbuild mints dev keys over time), so push today's
    # pubkeys first — explicit trust, never --allow-untrusted.
    if ls "${PROJECT_ROOT}/cports/etc/keys/"*.pub >/dev/null 2>&1; then
        "${SCP[@]}" "${PROJECT_ROOT}/cports/etc/keys/"*.pub \
            "root@${HOST}:/etc/apk/keys/" >/dev/null
    fi

    "${SSH[@]}" "apk add --repositories-file /dev/null /tmp/${base} && rm -f /tmp/${base}" || {
        say "ERROR: apk add ${base} failed on the device"
        return 1
    }
}

stream_log() {
    # dinit logfile convention: /var/log/<service>.log — stream until
    # Ctrl-C (docs/08 §6). Fall back to the description's logfile= line.
    local logfile
    logfile=$("${SSH[@]}" "f=/etc/dinit.d/${SERVICE}; [ -f \"\$f\" ] || f=/usr/lib/dinit.d/${SERVICE}; \
        awk -F' *= *' '\$1==\"logfile\"{print \$2; exit}' \"\$f\" 2>/dev/null")
    logfile="${logfile:-/var/log/${SERVICE}.log}"
    say "streaming ${logfile} (Ctrl-C to stop)"
    "${SSH[@]}" "tail -n 5 -f '${logfile}'"
}

##############################################################################
# Run (+ --watch loop: mtime poll, no inotify dependency)
##############################################################################
deploy_once || exit 1

if [ "$WATCH" = true ]; then
    ARTIFACT="${BINARY:-$PKG}"
    say "watching ${ARTIFACT} for changes (Ctrl-C to stop)"
    last=$(stat -c %Y "$ARTIFACT")
    while :; do
        sleep 1
        now=$(stat -c %Y "$ARTIFACT" 2>/dev/null || echo "$last")
        if [ "$now" != "$last" ]; then
            last="$now"
            deploy_once || say "WARN: redeploy failed; still watching"
        fi
    done
elif [ "$STREAM_LOG" = true ]; then
    stream_log
fi
