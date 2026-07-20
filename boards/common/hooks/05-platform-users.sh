# shellcheck shell=bash
# (sourced by build/lib/rootfs.sh run_hooks — not executed directly)
# Platform users/groups (docs/02 §7), present on every image:
#   astrod    (uid/gid 300)  the config daemon's unprivileged identity —
#                            all privileged operations go via D-Bus policy
#                            or dinit-dispatched oneshots, never root astrod
#   astro-api (gid 301)      membership = permission to use the astrod
#                            unix socket; app service users join it; the
#                            firstboot-generated API token is root:astro-api
# Runs before 10-create-users (lexical hook order) so variant users can
# declare astro-api group membership. Idempotent: skips existing entries.

create_platform_users() {
    local group_f="${ROOTFS_DIR}/etc/group"
    local passwd_f="${ROOTFS_DIR}/etc/passwd"
    local shadow_f="${ROOTFS_DIR}/etc/shadow"

    local shadow_mode=""
    if [ -f "$shadow_f" ]; then
        shadow_mode=$(stat -c %a "$shadow_f")
        chmod u+w "$shadow_f"
    fi

    grep -q '^astrod:' "$group_f" 2>/dev/null || \
        echo "astrod:x:300:" >> "$group_f"
    grep -q '^astro-api:' "$group_f" 2>/dev/null || \
        echo "astro-api:x:301:astrod" >> "$group_f"
    grep -q '^astrod:' "$passwd_f" 2>/dev/null || \
        echo "astrod:x:300:300:Astro config daemon:/var/empty:/bin/false" >> "$passwd_f"
    grep -q '^astrod:' "$shadow_f" 2>/dev/null || \
        echo "astrod:!:19000:0:99999:7:::" >> "$shadow_f"

    if [ -n "$shadow_mode" ]; then
        if [ "${ROOTFS_TYPE:-ext4}" = "squashfs" ]; then
            chmod "$shadow_mode" "$shadow_f"
        else
            chmod 600 "$shadow_f"
        fi
    fi

    log_info "Platform users present: astrod (300), astro-api group (301)"
}

create_platform_users
