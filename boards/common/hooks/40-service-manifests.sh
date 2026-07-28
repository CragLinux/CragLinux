# shellcheck shell=bash
# (sourced by build/lib/rootfs.sh run_hooks — not executed directly)
#
# M4 phase 1 — SERVICE MANIFEST ASSEMBLY (docs/08 §5).
#
# App apks install usr/lib/astro/services/<name>.toml next to their dinit
# service file. They arrive in the ASSEMBLED rootfs via apk (never via overlay
# — the code/config fence in merge.sh forbids app code in overlays). This hook
# reads every such manifest and wires the platform integration each app opted
# into. Numeric prefix 40 => runs AFTER 05-platform-users (astrod/astro-api),
# 10-create-users (variant users), 20-enable-services (platform + variant
# service enablement), so the astro-api group and the boot.d dir already exist.
#
# Hook environment (docs/08 §8): ROOTFS_DIR (the assembled rootfs), PROJECT_ROOT
# (repo root, for the reader), ROOTFS_TYPE, and the log_* helpers.
#
# NO-OP CONTRACT: with no manifests in the rootfs (the no-app / no-external-tree
# path — every current fleet image), read_manifests returns [] and this hook
# does nothing, so the image stays byte-identical and fleet CI stays green.
#
# Each effect below is a small, idempotent function; the assembly loop at the
# bottom (apply_service_manifests) reads the validated manifests via
# build/lib/service_manifest.py and dispatches them. api_controllable needs NO
# build-time effect — astrod reads the same manifests at startup
# (services.zig loadManifests, docs/06 §5.4) to learn which services its
# POST /services/<name>/{restart,stop,start} endpoints may touch.

# _svc_uid_taken <uid> — is <uid> already the uid of some passwd entry?
# Used to resolve app-user uid hash collisions by probing upward.
_svc_uid_taken() {
    awk -F: -v u="$1" '$3==u {found=1} END {exit found?0:1}' \
        "${ROOTFS_DIR}/etc/passwd" 2>/dev/null
}

# ---- effect (a): create [service].user as a system user -------------------
# Reuse the 05-platform-users.sh / 10-create-users.sh pattern: append group +
# passwd + shadow entries (guarded by the /etc/shadow writable-mode dance so a
# prod squashfs restores the packaged 000 mode, a dev ext4 keeps it 600 —
# rootfs-stage.sh must be able to read every file).
# The uid is the deterministic value from service_manifest.py (400-899 range,
# SHA-256 of the name — stable across builds); on a hash COLLISION with an
# already-assigned uid we probe upward within [400,899] and use the free slot
# (the reader owns the deterministic STARTING uid, this hook owns the final
# assignment — service_manifest.py "APP-USER UID SCHEME"). Skip when user == ""
# (the service runs as root — no user is created). Idempotent.
sm_effect_user() {
    local name="$1" user="$2" uid="$3"
    [ -n "$user" ] || return 0

    local passwd_f="${ROOTFS_DIR}/etc/passwd"
    local group_f="${ROOTFS_DIR}/etc/group"
    local shadow_f="${ROOTFS_DIR}/etc/shadow"

    # Idempotent: the user is already present (re-run, or a variant hook made
    # a user of the same name). Do not append a duplicate line.
    if grep -q "^${user}:" "$passwd_f" 2>/dev/null; then
        log_info "  [service-manifest] user ${user} already present; not recreating (${name})"
        return 0
    fi

    # Probe upward within [400,899] past any uid a collision already claimed.
    while _svc_uid_taken "$uid"; do
        uid=$((uid + 1))
        [ "$uid" -le 899 ] || \
            die "service-manifest: no free app-user uid in [400,899] for ${user} (${name}) — too many app users on this image (docs/08 §5)"
    done

    local shadow_mode=""
    if [ -f "$shadow_f" ]; then
        shadow_mode=$(stat -c %a "$shadow_f")
        chmod u+w "$shadow_f"
    fi

    # group (primary, same gid as uid), passwd (locked, /var/empty, /bin/false),
    # shadow (locked password) — a system identity, not a login account.
    grep -q "^${user}:" "$group_f" 2>/dev/null || \
        echo "${user}:x:${uid}:" >> "$group_f"
    echo "${user}:x:${uid}:${uid}:Astro app service (${name}):/var/empty:/bin/false" >> "$passwd_f"
    echo "${user}:!:19000:0:99999:7:::" >> "$shadow_f"

    if [ -n "$shadow_mode" ]; then
        if [ "${ROOTFS_TYPE:-ext4}" = "squashfs" ]; then
            chmod "$shadow_mode" "$shadow_f"
        else
            chmod 600 "$shadow_f"
        fi
    fi

    log_info "  [service-manifest] created app user ${user} (uid ${uid}) for ${name}"
}

# ---- effect (b): data_dir => /data/apps/<name> at RUNTIME -----------------
# /data is a RUNTIME mount (not present at build), so the dir cannot be made
# here. MECHANISM: record the request in a build-time list that the boot-time
# data-mount step (usr/lib/astro/data-mount.sh) replays — for each recorded
# "<name> <owner>" it `mkdir -p /data/apps/<name>` + `chown owner:owner` right
# after /data is mounted (see the followup edit to data-mount.sh). Owner
# defaults to root when the service declares no [service].user. ASTRO_DATA_DIR
# (effect c) points at the same path.
sm_effect_data_dir() {
    local name="$1" user="$2" data_dir="$3"
    [ "$data_dir" = "true" ] || return 0

    local dir="${ROOTFS_DIR}/etc/astro"
    mkdir -p "$dir"
    local rec="${dir}/app-data-dirs"
    local owner="${user:-root}"

    if [ -f "$rec" ] && grep -qxF "${name} ${owner}" "$rec"; then
        return 0
    fi
    echo "${name} ${owner}" >> "$rec"
    log_info "  [service-manifest] recorded /data/apps/${name} (owner ${owner}) for boot-time creation (data-mount.sh)"
}

# ---- effect (c): per-service env file (docs/08 §5) ------------------------
# Every app service gets ASTRO_API_SOCKET (=/run/astro/astrod.sock — astrod's
# default unix socket, main.zig) and, when data_dir, ASTRO_DATA_DIR
# (=/data/apps/<name>). dinit reads it via `env-file = <path>` in the app's OWN
# service description — the same 0.22 mechanism the iwd shadow already uses
# (etc/dinit.d/iwd: `env-file = /etc/astro/iwd.env`). PATH:
# /etc/astro/services/<name>.env. The app's service file must carry the line
#     env-file = /etc/astro/services/<name>.env
# (documented in docs/08 §5 / the acme example) — this hook only writes the
# file; it does not edit the app's service description.
sm_effect_env_file() {
    local name="$1" data_dir="$2"

    local dir="${ROOTFS_DIR}/etc/astro/services"
    mkdir -p "$dir"
    local f="${dir}/${name}.env"

    {
        echo "# Astro per-service environment (docs/08 §5) — generated at image"
        echo "# assembly by 40-service-manifests.sh. The app's dinit service"
        echo "# references it with: env-file = /etc/astro/services/${name}.env"
        echo "ASTRO_API_SOCKET=/run/astro/astrod.sock"
        if [ "$data_dir" = "true" ]; then
            echo "ASTRO_DATA_DIR=/data/apps/${name}"
        fi
    } > "$f"
    log_info "  [service-manifest] wrote env-file ${f#"${ROOTFS_DIR}"}"
}

# ---- effect (d): boot_success => depends-on of the milestone (AD-011) -----
# The service becomes a dependency of the boot-success milestone: if it fails
# to start after an update, rauc-mark-good never runs and the device rolls
# back (docs/05 §4). MECHANISM: append `depends-on: <name>` to the assembled
# /etc/dinit.d/boot-success (it already lists `depends-on: astrod` /
# `depends-on: data-mount`). Idempotent.
sm_effect_boot_success() {
    local name="$1" boot_success="$2"
    [ "$boot_success" = "true" ] || return 0

    local f="${ROOTFS_DIR}/etc/dinit.d/boot-success"
    if [ ! -f "$f" ]; then
        die "service-manifest: ${name} sets boot_success=true but ${f} is missing (docs/08 §5, AD-011)"
    fi
    if grep -qxF "depends-on: ${name}" "$f"; then
        return 0
    fi
    echo "depends-on: ${name}" >> "$f"
    log_info "  [service-manifest] boot-success now depends-on ${name} (rollback opt-in, AD-011)"
}

# ---- effect (e): api_client => join the astro-api group -------------------
# Membership in astro-api is permission to use astrod's unix socket (docs/02
# §7). The group exists from 05-platform-users.sh (gid 301). Append the user
# to the group's member field. Idempotent.
sm_effect_api_group() {
    local name="$1" user="$2" api_client="$3"
    [ "$api_client" = "true" ] || return 0

    local group_f="${ROOTFS_DIR}/etc/group"
    if [ -z "$user" ]; then
        log_warn "  [service-manifest] ${name}: api_client=true but no [service].user — nothing to add to astro-api (root already has socket access)"
        return 0
    fi
    if ! grep -q '^astro-api:' "$group_f" 2>/dev/null; then
        log_warn "  [service-manifest] astro-api group missing (05-platform-users) — cannot join ${user} (${name})"
        return 0
    fi
    # Already a member? (exact match on a member-list element, not a substring.)
    if awk -F: -v u="$user" '$1=="astro-api"{n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]==u) exit 0; exit 1}' "$group_f"; then
        return 0
    fi
    # Append to the 4th field, handling an empty member list without a stray
    # leading comma.
    local tmp="${group_f}.tmp.$$"
    awk -F: -v u="$user" 'BEGIN{OFS=":"} $1=="astro-api"{$4=($4==""?u:$4","u)} {print}' \
        "$group_f" > "$tmp" && mv "$tmp" "$group_f"
    log_info "  [service-manifest] added ${user} to astro-api group (${name})"
}

# ---- effect (g): JSON sidecar for astrod (docs/06 §5.4, docs/08 §5) -------
# astrod cannot parse the .toml manifests at runtime (std has no TOML parser;
# AD-016 no shelling out), so it reads a JSON sidecar per service. Emit
# usr/lib/astro/services/<name>.json — the manifest's full to_dict() object,
# beside the <name>.toml. astrod (services.zig loadManifests) consumes only
# `name` + `api_controllable` (ignore_unknown_fields), so shipping the whole
# dict is fine and future-proof. Zero manifests => zero sidecars => astrod's
# loadManifests is a no-op and the no-app image stays byte-identical.
sm_effect_sidecar() {
    local name="$1" element_json="$2"
    local dir="${ROOTFS_DIR}/usr/lib/astro/services"
    mkdir -p "$dir"
    # Drop source_path: it is a build-host absolute path (leaks the builder's
    # filesystem into the image and astrod never reads it).
    printf '%s\n' "$element_json" | jq -S 'del(.source_path)' > "${dir}/${name}.json"
    log_info "  [service-manifest] wrote sidecar usr/lib/astro/services/${name}.json (astrod)"
}

# ---- effect (f): enable the service into boot.d ---------------------------
# Default: enable (docs/08 §5 — "enable the service, or the tree's hook enables
# conditionally"). Mirror the boot.d symlink shape 20-enable-services uses:
# /etc-local services link ../<name>, packaged services link
# ../../../usr/lib/dinit.d/<name>. Idempotent (ln -sf).
sm_effect_enable() {
    local name="$1"
    local boot_d="${ROOTFS_DIR}/etc/dinit.d/boot.d"
    mkdir -p "$boot_d"

    local target
    if [ -f "${ROOTFS_DIR}/etc/dinit.d/${name}" ]; then
        target="../${name}"
    elif [ -f "${ROOTFS_DIR}/usr/lib/dinit.d/${name}" ]; then
        target="../../../usr/lib/dinit.d/${name}"
    else
        log_warn "  [service-manifest] no service description for ${name} in /etc/dinit.d or /usr/lib/dinit.d (enabling by name anyway)"
        target="../${name}"
    fi
    ln -sf "$target" "${boot_d}/${name}"
    log_info "  [service-manifest] enabled ${name} into boot.d (-> ${target})"
}

apply_service_manifests() {
    local reader="${PROJECT_ROOT}/build/lib/service_manifest.py"
    if [ ! -f "$reader" ]; then
        log_warn "service_manifest.py not found (${reader}); skipping manifest assembly"
        return 0
    fi

    local manifests_json
    if ! manifests_json=$(python3 "$reader" read "$ROOTFS_DIR"); then
        die "service manifest validation failed (docs/08 §5) — see the error above"
    fi

    local count
    count=$(echo "$manifests_json" | jq 'length')
    if [ "${count:-0}" -eq 0 ]; then
        # The no-app path: nothing installed a manifest. Byte-identical image.
        return 0
    fi

    log_step "Assembling ${count} service manifest(s) (docs/08 §5)..."

    local i name user uid data_dir boot_success api_controllable api_client element
    for i in $(seq 0 $((count - 1))); do
        element=$(echo "$manifests_json"          | jq ".[$i]")
        name=$(echo "$manifests_json"             | jq -r ".[$i].name")
        user=$(echo "$manifests_json"             | jq -r ".[$i].user")
        uid=$(echo "$manifests_json"              | jq -r ".[$i].uid")
        data_dir=$(echo "$manifests_json"         | jq -r ".[$i].data_dir")
        boot_success=$(echo "$manifests_json"     | jq -r ".[$i].boot_success")
        api_controllable=$(echo "$manifests_json" | jq -r ".[$i].api_controllable")
        api_client=$(echo "$manifests_json"       | jq -r ".[$i].api_client")

        log_info "  service manifest: ${name} (user=${user:-<root>}, data_dir=${data_dir}, boot_success=${boot_success}, api_controllable=${api_controllable}, api_client=${api_client})"

        # api_controllable needs NO build-time effect: astrod reads the same
        # manifests at startup (services.zig loadManifests) to learn which
        # services POST /services/<name>/{restart,stop,start} may touch
        # (docs/06 §5.4). It is surfaced here only for the assembly log.

        sm_effect_user         "$name" "$user" "$uid"
        sm_effect_data_dir     "$name" "$user" "$data_dir"
        sm_effect_env_file     "$name" "$data_dir"
        sm_effect_boot_success "$name" "$boot_success"
        sm_effect_api_group    "$name" "$user" "$api_client"
        sm_effect_sidecar      "$name" "$element"
        sm_effect_enable       "$name"
    done

    log_info "Service manifests assembled"
}

apply_service_manifests
