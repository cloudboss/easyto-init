#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
OUTPUT_DIR="${PROJECT_ROOT}/_output"
INTEGRATION_OUT="${OUTPUT_DIR}/integration"

# Kernel and assets from easyto-assets
EASYTO_ASSETS_RUNTIME="${OUTPUT_DIR}/easyto-assets-runtime-v0.3.0"
KERNEL="${OUTPUT_DIR}/vmlinuz"

# Built init binary
INIT_BINARY="${OUTPUT_DIR}/target/x86_64-unknown-linux-musl/release/init"

# Test image
INITRAMFS="${INTEGRATION_OUT}/initramfs.cpio.gz"

# Timeout for each test (seconds)
TIMEOUT=90
VERBOSE="${VERBOSE:-}"

log()
{
    echo "[integration] $*"
}

die()
{
    echo "[integration] ERROR: $*" >&2
    exit 1
}

check_prerequisites()
{
    [ -f "${INIT_BINARY}" ] || die "init binary not found at ${INIT_BINARY} - run 'make test' first"
    [ -f "${KERNEL}" ] || die "kernel not found at ${KERNEL}"
    [ -d "${EASYTO_ASSETS_RUNTIME}" ] || die "easyto-assets-runtime not found at ${EASYTO_ASSETS_RUNTIME}"
    command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found"
}

build_test_image()
{
    log "Building test image..."
    mkdir -p "${INTEGRATION_OUT}"
    "${SCRIPT_DIR}/image/build.sh" "${INIT_BINARY}" "${EASYTO_ASSETS_RUNTIME}" "${INITRAMFS}"
}

run_scenario()
{
    scenario_name="$1"
    scenario_dir="${SCRIPT_DIR}/scenarios/${scenario_name}"

    [ -d "${scenario_dir}" ] || die "scenario not found: ${scenario_name}"

    log "Running scenario: ${scenario_name}"

    # Capture serial output
    output_file="${INTEGRATION_OUT}/${scenario_name}.log"

    # Pass scenario name via kernel command line
    kernel_cmdline="rdinit=/init-wrapper console=ttyS0 panic=-1 scenario=${scenario_name}"

    # Run QEMU with timeout
    set +e
    if [ -n "${VERBOSE}" ]; then
        # Show output in real-time while also capturing to file
        timeout "${TIMEOUT}" qemu-system-x86_64 \
            -accel kvm -accel tcg \
            -m 512 \
            -kernel "${KERNEL}" \
            -initrd "${INITRAMFS}" \
            -append "${kernel_cmdline}" \
            -nographic \
            -device e1000,netdev=net0 \
            -netdev user,id=net0 \
            -no-reboot \
            2>&1 | tee "${output_file}"
        # Get exit code from timeout via a temp file since PIPESTATUS isn't portable
        exit_code=0
        if ! grep -q "^PASS" "${output_file}" 2>/dev/null; then
            if grep -q "^FAIL" "${output_file}" 2>/dev/null; then
                exit_code=1
            fi
        fi
    else
        timeout "${TIMEOUT}" qemu-system-x86_64 \
            -accel kvm -accel tcg \
            -m 512 \
            -kernel "${KERNEL}" \
            -initrd "${INITRAMFS}" \
            -append "${kernel_cmdline}" \
            -nographic \
            -device e1000,netdev=net0 \
            -netdev user,id=net0 \
            -no-reboot \
            > "${output_file}" 2>&1
        exit_code=$?
    fi
    set -e

    # Check results
    if [ ${exit_code} -eq 124 ]; then
        log "TIMEOUT: ${scenario_name} (${TIMEOUT}s exceeded)"
        cat "${output_file}"
        return 1
    fi

    # Strip carriage returns from serial console output for pattern matching
    tr -d '\r' < "${output_file}" > "${output_file}.clean"

    if grep -q "^PASS$" "${output_file}.clean"; then
        log "PASS: ${scenario_name}"
        rm -f "${output_file}.clean"
        return 0
    elif grep -q "^FAIL" "${output_file}.clean"; then
        log "FAIL: ${scenario_name}"
        grep "^FAIL" "${output_file}.clean"
        cat "${output_file}"
        rm -f "${output_file}.clean"
        return 1
    else
        log "UNKNOWN: ${scenario_name} (no PASS/FAIL marker)"
        cat "${output_file}"
        rm -f "${output_file}.clean"
        return 1
    fi
}

main()
{
    check_prerequisites
    build_test_image

    failed=0

    for scenario_dir in "${SCRIPT_DIR}/scenarios"/*/; do
        scenario_name=$(basename "${scenario_dir}")
        if ! run_scenario "${scenario_name}"; then
            failed=$((failed + 1))
        fi
    done

    if [ ${failed} -gt 0 ]; then
        log "${failed} scenario(s) failed"
        exit 1
    fi

    log "All scenarios passed"
}

main "$@"
