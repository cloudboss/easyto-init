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

# Mock IMDS server
IMDS_PORT=8080
IMDS_PID=""

# Timeout for each test (seconds)
TIMEOUT=90
VERBOSE="${VERBOSE:-}"
SCENARIO="${SCENARIO:-}"

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
    command -v python3 >/dev/null || die "python3 not found"
}

build_test_image()
{
    log "Building test image..."
    mkdir -p "${INTEGRATION_OUT}"
    "${SCRIPT_DIR}/image/build.sh" "${INIT_BINARY}" "${EASYTO_ASSETS_RUNTIME}" "${INITRAMFS}"
}

start_mock_imds()
{
    scenario_name="$1"
    log "Starting mock IMDS server for scenario: ${scenario_name}"
    python3 "${SCRIPT_DIR}/mocks/imds_server.py" \
        "${IMDS_PORT}" \
        "${SCRIPT_DIR}/scenarios" \
        "${scenario_name}" \
        > "${INTEGRATION_OUT}/imds-${scenario_name}.log" 2>&1 &
    IMDS_PID=$!

    # Wait for server to be ready
    for i in $(seq 1 50); do
        if curl -s -o /dev/null "http://127.0.0.1:${IMDS_PORT}/latest/meta-data/instance-id" 2>/dev/null; then
            log "Mock IMDS server ready (pid ${IMDS_PID})"
            return 0
        fi
        sleep 0.1
    done
    die "Mock IMDS server failed to start"
}

stop_mock_imds()
{
    if [ -n "${IMDS_PID}" ]; then
        kill "${IMDS_PID}" 2>/dev/null || true
        wait "${IMDS_PID}" 2>/dev/null || true
        IMDS_PID=""
    fi
}

run_scenario()
{
    scenario_name="$1"
    scenario_dir="${SCRIPT_DIR}/scenarios/${scenario_name}"

    [ -d "${scenario_dir}" ] || die "scenario not found: ${scenario_name}"

    log "Running scenario: ${scenario_name}"

    # Start mock IMDS server for this scenario
    start_mock_imds "${scenario_name}"

    # Capture serial output
    output_file="${INTEGRATION_OUT}/${scenario_name}.log"

    # Kernel command line with environment variables for init
    # - EASYTO_TEST_MODE: enables test-specific behavior (chmod /dev/ttyS0)
    # - AWS_EC2_METADATA_SERVICE_ENDPOINT: points to host-side mock IMDS
    kernel_cmdline="rdinit=/.easyto/sbin/init console=ttyS0 panic=-1"
    kernel_cmdline="${kernel_cmdline} EASYTO_TEST_MODE=1"
    kernel_cmdline="${kernel_cmdline} AWS_EC2_METADATA_SERVICE_ENDPOINT=http://10.0.2.2:${IMDS_PORT}"

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

    # Stop mock IMDS server
    stop_mock_imds

    # Check results
    if [ ${exit_code} -eq 124 ]; then
        log "TIMEOUT: ${scenario_name} (${TIMEOUT}s exceeded)"
        cat "${output_file}"
        return 1
    fi

    # Strip carriage returns from serial console output for pattern matching
    tr -d '\r' < "${output_file}" > "${output_file}.clean"

    # Check for expected-output file (for error-handling tests)
    if [ -f "${scenario_dir}/expected-output" ]; then
        if grep -qf "${scenario_dir}/expected-output" "${output_file}.clean"; then
            log "PASS: ${scenario_name}"
            rm -f "${output_file}.clean"
            return 0
        else
            log "FAIL: ${scenario_name} (expected output not found)"
            log "Expected pattern:"
            cat "${scenario_dir}/expected-output"
            log "Actual output:"
            cat "${output_file}"
            rm -f "${output_file}.clean"
            return 1
        fi
    elif grep -q "^PASS$" "${output_file}.clean"; then
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

cleanup()
{
    stop_mock_imds
}

main()
{
    trap cleanup EXIT

    check_prerequisites
    build_test_image

    failed=0

    if [ -n "${SCENARIO}" ]; then
        # Run single scenario
        if ! run_scenario "${SCENARIO}"; then
            failed=1
        fi
    else
        # Run all scenarios
        for scenario_dir in "${SCRIPT_DIR}/scenarios"/*/; do
            scenario_name=$(basename "${scenario_dir}")
            if ! run_scenario "${scenario_name}"; then
                failed=$((failed + 1))
            fi
        done
    fi

    if [ ${failed} -gt 0 ]; then
        log "${failed} scenario(s) failed"
        exit 1
    fi

    log "All scenarios passed"
}

main "$@"
