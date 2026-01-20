#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INIT_BINARY="$1"
EASYTO_ASSETS_RUNTIME="$2"
OUTPUT="$3"

ROOTFS_DIR=$(mktemp -d)
trap "rm -rf ${ROOTFS_DIR}" EXIT

log()
{
    echo "[build-image] $*"
}

log "Creating test rootfs..."

# Create basic directory structure
mkdir -p "${ROOTFS_DIR}"/{bin,sbin,etc,proc,sys,dev,tmp,root}
mkdir -p "${ROOTFS_DIR}/.easyto"/{sbin,etc,run,services}

# Use docker to get a minimal alpine rootfs with Python for mock IMDS
log "Extracting alpine rootfs..."
container_id=$(docker create alpine:3.20 sh -c "apk add --no-cache python3 && rm -rf /var/cache/apk/*")
docker start -a "${container_id}" > /dev/null
docker export "${container_id}" | tar -xf - -C "${ROOTFS_DIR}"
docker rm "${container_id}" > /dev/null

# Extract all asset tarballs from easyto-assets-runtime onto rootfs
log "Installing easyto-assets-runtime..."
for tarball in "${EASYTO_ASSETS_RUNTIME}"/*.tar; do
    [ -f "${tarball}" ] || continue
    log "  Extracting $(basename "${tarball}")..."
    tar -xf "${tarball}" -C "${ROOTFS_DIR}"
done

# Install the init binary
log "Installing init binary..."
install -m 0755 "${INIT_BINARY}" "${ROOTFS_DIR}/.easyto/sbin/init"

# Create symlink for init
ln -sf /.easyto/sbin/init "${ROOTFS_DIR}/sbin/init"

# Install init-wrapper
log "Installing init-wrapper..."
install -m 0755 "${SCRIPT_DIR}/init-wrapper" "${ROOTFS_DIR}/init-wrapper"

# Install mock IMDS server
log "Installing mock IMDS server..."
install -m 0755 "${SCRIPT_DIR}/../mocks/imds_server.py" "${ROOTFS_DIR}/imds_server.py"

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

# Create initramfs
log "Creating initramfs..."
(cd "${ROOTFS_DIR}" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9) > "${OUTPUT}"

log "Created ${OUTPUT}"
