# shellcheck shell=bash
# (sourced by build/lib/rootfs.sh run_hooks — not executed directly)
# Create users defined in variant config
# Expects VARIANT_USERS_CREATE as JSON array (set by config loader)

create_users() {
    if [ -z "${USERS_CREATE:-}" ]; then
        return 0
    fi

    local count
    count=$(echo "$USERS_CREATE" | jq 'length')

    # /etc/shadow ships mode 000 from the shadow package; make it writable
    # for the append below and restore afterwards.
    local shadow_mode=""
    if [ -f "${ROOTFS_DIR}/etc/shadow" ]; then
        shadow_mode=$(stat -c %a "${ROOTFS_DIR}/etc/shadow")
        chmod u+w "${ROOTFS_DIR}/etc/shadow"
    fi

    for i in $(seq 0 $((count - 1))); do
        local name uid groups shell
        name=$(echo "$USERS_CREATE" | jq -r ".[$i].name")
        uid=$(echo "$USERS_CREATE" | jq -r ".[$i].uid")
        groups=$(echo "$USERS_CREATE" | jq -r ".[$i].groups // [] | join(\",\")")
        shell=$(echo "$USERS_CREATE" | jq -r ".[$i].shell // \"/bin/sh\"")

        # Create group
        echo "${name}:x:${uid}:" >> "${ROOTFS_DIR}/etc/group"

        # Create passwd entry
        echo "${name}:x:${uid}:${uid}::/home/${name}:${shell}" >> "${ROOTFS_DIR}/etc/passwd"

        # Create shadow entry (locked password)
        echo "${name}:!:19000:0:99999:7:::" >> "${ROOTFS_DIR}/etc/shadow"

        # Add to supplementary groups
        if [ -n "$groups" ]; then
            IFS=',' read -ra group_list <<< "$groups"
            for grp in "${group_list[@]}"; do
                if grep -q "^${grp}:" "${ROOTFS_DIR}/etc/group" 2>/dev/null; then
                    sed -i "s/^\(${grp}:.*\)/\1,${name}/" "${ROOTFS_DIR}/etc/group"
                else
                    echo "${grp}:x:${uid}:${name}" >> "${ROOTFS_DIR}/etc/group"
                fi
            done
        fi

        # Create home directory
        mkdir -p "${ROOTFS_DIR}/home/${name}"
        chown "${uid}:${uid}" "${ROOTFS_DIR}/home/${name}"

        log_info "Created user: ${name} (uid=${uid}, groups=${groups}, shell=${shell})"
    done

    local f
    if [ "${ROOTFS_TYPE:-ext4}" = "squashfs" ]; then
        # Prod path: restore the packaged shadow permissions. The stage runs
        # as root inside a user namespace (unshare -r, see rootfs-stage.sh),
        # so mksquashfs can read 000-mode files and records root ownership —
        # no readability workaround needed or wanted on a production image.
        # /etc/shadow -> packaged 000; backups (shadow- etc.) -> 600 root.
        if [ -n "$shadow_mode" ]; then
            chmod "$shadow_mode" "${ROOTFS_DIR}/etc/shadow"
        fi
        for f in shadow- gshadow gshadow- passwd- group-; do
            [ -f "${ROOTFS_DIR}/etc/${f}" ] && chmod 600 "${ROOTFS_DIR}/etc/${f}"
        done
    else
        # Dev path (GAP fix #11, dev-only): leave /etc/shadow owner-readable
        # (600) rather than the packaged 000 — the unprivileged dev-image
        # path (mkfs.ext4 -d) must be able to read every file. Same for the
        # shadow-suite backup files the pwconv/grpconv trigger leaves at 000.
        if [ -n "$shadow_mode" ]; then
            chmod 600 "${ROOTFS_DIR}/etc/shadow"
        fi
        for f in shadow- gshadow gshadow- passwd- group-; do
            [ -f "${ROOTFS_DIR}/etc/${f}" ] && chmod u+rw "${ROOTFS_DIR}/etc/${f}"
        done
    fi
    return 0
}

create_users
