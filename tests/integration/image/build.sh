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

# Use docker to get a minimal alpine rootfs with Python for mock IMDS
log "Extracting alpine rootfs..."
container_id=$(docker create alpine:3.20 sh -c "apk add --no-cache python3 && rm -rf /var/cache/apk/*")
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

# Install scenario user-data files
log "Installing scenario user-data files..."
mkdir -p "${ROOTFS_DIR}/scenarios"
for scenario_dir in "${SCRIPT_DIR}/../scenarios"/*/; do
    [ -d "${scenario_dir}" ] || continue
    scenario_name=$(basename "${scenario_dir}")
    mkdir -p "${ROOTFS_DIR}/scenarios/${scenario_name}"
    if [ -f "${scenario_dir}/user-data.yaml" ]; then
        cp "${scenario_dir}/user-data.yaml" "${ROOTFS_DIR}/scenarios/${scenario_name}/"
        log "  Installed ${scenario_name}/user-data.yaml"
    fi
done

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

# Create initramfs with fakeroot to preserve root ownership
log "Creating initramfs..."
(cd "${ROOTFS_DIR}" && fakeroot sh -c 'chown -R 0:0 . && find . -print0 | cpio --null -o -H newc' 2>/dev/null | gzip -9) > "${OUTPUT}"

log "Created ${OUTPUT}"
