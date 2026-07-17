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

    # Leave /etc/shadow owner-readable (600) rather than the packaged 000:
    # the unprivileged dev-image path (mkfs.ext4 -d) must be able to read
    # every file. 000 is shadow's packaged mode; the prod image path should
    # restore it (or build under fakeroot). See GAP-REPORT §3.5.
    if [ -n "$shadow_mode" ]; then
        chmod 600 "${ROOTFS_DIR}/etc/shadow"
    fi

    # Same treatment for the shadow-suite backup files: the shadow package
    # trigger (pwconv/grpconv) leaves e.g. /etc/shadow- at mode 000, which
    # breaks the unprivileged mkfs.ext4 -d read of the tree.
    local f
    for f in shadow- gshadow gshadow- passwd- group-; do
        [ -f "${ROOTFS_DIR}/etc/${f}" ] && chmod u+rw "${ROOTFS_DIR}/etc/${f}"
    done
    return 0
}

create_users
