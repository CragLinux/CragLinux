#!/bin/bash
#
# Astro Linux - RAUC bundle stage (docs/05 §3, AD-010; M2)
#
# Packs the built slot images into a signed RAUC bundle:
#
#   [image.rootfs]  prod: the squashfs; dev: the slot ext4 from image-work
#                   (identical bits to what the full image carries), with
#                   adaptive=block-hash-index so devices only fetch
#                   changed blocks on streamed installs
#   [image.boot]    image-work/boot.vfat (kernel + dtbs slot image)
#
# Format is verity (AD-010 — devices reject plain), signed with the dev
# PKI (keys/dev, docs/05 §6; release signing swaps the cert/key via
# RAUC_SIGN_CERT/RAUC_SIGN_KEY when the release pipeline lands).
#
# Output: <out>/astro-<board>-<version>.raucb + .raucb.info (rauc info
# dump, verified against the device keyring).

create_bundle() {
    local board="$1"
    local variant="$2"
    local rootfs_type="$3"
    local board_config_json="$4"

    local out_dir="${PROJECT_ROOT}/build/state/images/${board}-${variant}"
    local work="${out_dir}/image-work"
    local version="${ASTRO_VERSION:-0.0.0-dev}"

    local compatible
    compatible=$(echo "$board_config_json" | jq -r '.rauc.compatible')

    log_step "Creating RAUC bundle for ${board}/${variant} (${compatible}, ${version})..."

    require_command rauc

    # Slot payloads — must be the exact images the image stage used
    local rootfs_img
    if [ "$rootfs_type" = "squashfs" ]; then
        rootfs_img="${out_dir}/rootfs.squashfs"
    else
        rootfs_img="${work}/rootfs.ext4"
    fi
    [ -f "$rootfs_img" ] || die "rootfs slot image not found: ${rootfs_img} (run --step=image first)"
    local boot_img="${work}/boot.vfat"
    [ -f "$boot_img" ] || die "boot slot image not found: ${boot_img} (run --step=image first)"

    # Signing material (dev PKI unless overridden)
    local cert="${RAUC_SIGN_CERT:-${PROJECT_ROOT}/keys/dev/rauc-signing.cert.pem}"
    local key="${RAUC_SIGN_KEY:-${PROJECT_ROOT}/keys/dev/rauc-signing.key.pem}"
    local keyring="${RAUC_KEYRING:-${PROJECT_ROOT}/keys/dev/rauc-ca.pem}"
    [ -f "$cert" ] && [ -f "$key" ] || \
        die "RAUC signing cert/key not found (${cert}).\n  Run: ./build/astro-keys.sh init-dev"

    # Assemble the bundle input dir
    local bdl_work="${work}/bundle"
    rm -rf "$bdl_work"
    mkdir -p "$bdl_work"
    cp --reflink=auto "$rootfs_img" "${bdl_work}/rootfs.img"
    cp --reflink=auto "$boot_img" "${bdl_work}/boot.vfat"

    cat > "${bdl_work}/manifest.raucm" <<EOF
[update]
compatible=${compatible}
version=${version}

[bundle]
format=verity

[image.rootfs]
filename=rootfs.img
adaptive=block-hash-index

[image.boot]
filename=boot.vfat
EOF

    local bundle_out="${out_dir}/astro-${board}-${version}.raucb"
    rm -f "$bundle_out"
    rauc bundle \
        --cert="$cert" \
        --key="$key" \
        "$bdl_work" "$bundle_out" || die "rauc bundle failed"

    # Verify against the device keyring and keep the info dump as evidence
    rauc info --keyring="$keyring" "$bundle_out" > "${bundle_out}.info" 2>&1 || \
        die "bundle verification against keyring failed: $(cat "${bundle_out}.info")"

    rm -rf "$bdl_work"

    # Refresh SHA256SUMS with the bundle
    if [ -f "${out_dir}/SHA256SUMS" ]; then
        (cd "$out_dir" && grep -v "$(basename "$bundle_out")" SHA256SUMS > SHA256SUMS.tmp 2>/dev/null || :;
         sha256sum "$(basename "$bundle_out")" >> SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS)
    fi

    log_info "RAUC bundle: ${bundle_out} ($(du -h "$bundle_out" | cut -f1))"
    log_info "  info:      ${bundle_out}.info"
}
