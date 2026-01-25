#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INIT_BINARY="$1"
EASYTO_ASSETS_RUNTIME="$2"
OUTPUT="$3"
SCENARIO_DIR="${4:-}"

# Cache in the main output directory (_output/)
OUTPUT_DIR=$(cd "$(dirname "${OUTPUT}")/.." && pwd)

# Generate cache key from alpine image and assets version
ALPINE_IMAGE="alpine:3.20"
ASSETS_VERSION=$(basename "${EASYTO_ASSETS_RUNTIME}")
CACHE_KEY=$(echo "${ALPINE_IMAGE}:${ASSETS_VERSION}" | sha256sum | cut -c1-16)
CACHE_FILE="${OUTPUT_DIR}/test-rootfs-${CACHE_KEY}.tar"

ROOTFS_DIR=$(mktemp -d)
trap "rm -rf ${ROOTFS_DIR}" EXIT

log()
{
    echo "[build-image] $*"
}

build_base_rootfs()
{
    log "Creating test rootfs..."

    # Use docker to get a minimal alpine rootfs with curl for IMDS testing
    log "Extracting alpine rootfs..."
    container_id=$(docker create ${ALPINE_IMAGE} sh -c "apk add --no-cache curl && rm -rf /var/cache/apk/*")
    docker start -a "${container_id}" > /dev/null
    docker export "${container_id}" | fakeroot tar -xf - -C "${ROOTFS_DIR}"
    docker rm "${container_id}" > /dev/null

    # Extract all asset tarballs from easyto-assets-runtime onto rootfs
    log "Installing easyto-assets-runtime..."
    for tarball in "${EASYTO_ASSETS_RUNTIME}"/*.tar; do
        [ -f "${tarball}" ] || continue
        log "  Extracting $(basename "${tarball}")..."
        fakeroot tar -xf "${tarball}" -C "${ROOTFS_DIR}"
    done

    # Add service users required by chrony
    log "Adding service users..."
    echo "cb-chrony:x:400:400:chrony:/var/lib/chrony:/sbin/nologin" >> "${ROOTFS_DIR}/etc/passwd"
    echo "cb-chrony:x:400:" >> "${ROOTFS_DIR}/etc/group"

    # Save to cache
    log "Saving rootfs cache..."
    (cd "${ROOTFS_DIR}" && fakeroot tar -cf "${CACHE_FILE}" .)
}

# Check for cached rootfs
if [ -f "${CACHE_FILE}" ]; then
    log "Using cached rootfs (${CACHE_KEY})..."
    fakeroot tar -xf "${CACHE_FILE}" -C "${ROOTFS_DIR}"
else
    build_base_rootfs
fi

# Install the init binary
log "Installing init binary..."
install -m 0755 "${INIT_BINARY}" "${ROOTFS_DIR}/.easyto/sbin/init"

# Create symlink for init
ln -sf /.easyto/sbin/init "${ROOTFS_DIR}/sbin/init"

# Install test entrypoint (will be overridden per-scenario via user-data)
install -m 0755 "${SCRIPT_DIR}/test-entrypoint" "${ROOTFS_DIR}/test-entrypoint"

# Create metadata.json (container config)
cat > "${ROOTFS_DIR}/.easyto/metadata.json" << 'EOF'
{
  "config": {
    "Cmd": ["/test-entrypoint"],
    "Entrypoint": null,
    "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "User": "0:0",
    "WorkingDir": "/"
  }
}
EOF

# Apply scenario-specific overlay if present
if [ -n "${SCENARIO_DIR}" ] && [ -d "${SCENARIO_DIR}/overlay" ]; then
    log "Applying overlay from ${SCENARIO_DIR}/overlay..."
    fakeroot cp -a "${SCENARIO_DIR}/overlay/." "${ROOTFS_DIR}/"
fi

# Create initramfs with fakeroot to preserve root ownership
log "Creating initramfs..."
(cd "${ROOTFS_DIR}" && fakeroot sh -c 'chown -R 0:0 . && find . -print0 | cpio --null -o -H newc' 2>/dev/null | gzip -9) > "${OUTPUT}"

log "Created ${OUTPUT}"
