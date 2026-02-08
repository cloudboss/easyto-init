#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
OUTPUT_DIR="${PROJECT_ROOT}/_output"
EASYTO_ASSETS_VERSION=${EASYTO_ASSETS_VERSION:?EASYTO_ASSETS_VERSION must be defined}
CTR_IMAGE_ALPINE=${CTR_IMAGE_ALPINE:?CTR_IMAGE_ALPINE must be defined}

# Create temp directory for this test run
mkdir -p "${OUTPUT_DIR}"
INTEGRATION_OUT="${OUTPUT_DIR}/$(cd "${OUTPUT_DIR}" && mktemp -d integration.XXXXXX)"

# Kernel and assets from easyto-assets
EASYTO_ASSETS_RUNTIME="${OUTPUT_DIR}/easyto-assets-runtime-${EASYTO_ASSETS_VERSION}"
KERNEL="${OUTPUT_DIR}/vmlinuz"

# Built init binary
INIT_BINARY="${OUTPUT_DIR}/target/x86_64-unknown-linux-musl/release/init"

# Test image
INITRAMFS="${INTEGRATION_OUT}/initramfs.cpio.gz"

# Mock IMDS server
IMDS_PORT=8080
IMDS_PID=""

# LocalStack for AWS service mocking (S3, SSM, Secrets Manager)
LOCALSTACK_PORT=4566
LOCALSTACK_CONTAINER=""

# Timeout for each test (seconds)
TIMEOUT=90
VERBOSE="${VERBOSE:-}"
SCENARIO="${SCENARIO:-}"
KEEP_LOGS="${KEEP_LOGS:-}"

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
    local build_scenario_dir="${1:-}"
    log "Building test image..."
    mkdir -p "${INTEGRATION_OUT}"
    ${SCRIPT_DIR}/image/build.sh \
        "${CTR_IMAGE_ALPINE}" \
        "${INIT_BINARY}" \
        "${EASYTO_ASSETS_RUNTIME}" \
        "${INITRAMFS}" \
        "${build_scenario_dir}"
}

get_scenario_config()
{
    scenario_name="$1"
    config_key="$2"
    default_value="$3"
    config_file="${SCRIPT_DIR}/scenarios/${scenario_name}/config"

    if [ -f "${config_file}" ]; then
        value=$(grep "^${config_key}=" "${config_file}" 2>/dev/null | cut -d= -f2)
        if [ -n "${value}" ]; then
            echo "${value}"
            return
        fi
    fi
    echo "${default_value}"
}

generate_qemu_nic_args()
{
    nic_count="$1"
    # Generate QEMU NIC arguments for multiple NICs
    # MACs are sequential from 52:54:00:12:34:56
    i=0
    while [ $i -lt "$nic_count" ]; do
        mac_suffix=$(printf "%02x" $((86 + i)))
        echo "-device e1000,netdev=net${i},mac=52:54:00:12:34:${mac_suffix}"
        echo "-netdev user,id=net${i}"
        i=$((i + 1))
    done
}

start_mock_imds()
{
    scenario_name="$1"
    nic_count="$2"
    spot_termination_delay="$3"
    log "Starting mock IMDS server for scenario: ${scenario_name} (${nic_count} NICs, spot_delay=${spot_termination_delay}s)"
    python3 "${SCRIPT_DIR}/mocks/imds_server.py" \
        "${IMDS_PORT}" \
        "${SCRIPT_DIR}/scenarios" \
        "${scenario_name}" \
        "${nic_count}" \
        "${spot_termination_delay}" \
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

start_localstack()
{
    scenario_name="$1"
    log "Starting LocalStack for scenario: ${scenario_name}"

    # Check for docker
    command -v docker >/dev/null || die "docker not found (required for LocalStack)"

    # Get current container ID to share network namespace
    # This allows LocalStack to be accessible via 127.0.0.1 from this container
    # and via 10.0.2.2 from QEMU
    CONTAINER_ID=$(cat /proc/self/cgroup 2>/dev/null | grep -o '[0-9a-f]\{64\}' | head -1 || true)
    if [ -z "${CONTAINER_ID}" ]; then
        CONTAINER_ID=$(hostname 2>/dev/null || true)
    fi

    if [ -n "${CONTAINER_ID}" ] && docker inspect "${CONTAINER_ID}" >/dev/null 2>&1; then
        log "Sharing network with container ${CONTAINER_ID:0:12}"
        NETWORK_ARG="--network container:${CONTAINER_ID}"
    else
        log "Using host port mapping"
        NETWORK_ARG="-p ${LOCALSTACK_PORT}:4566"
    fi

    # Start LocalStack container
    LOCALSTACK_CONTAINER=$(docker run -d --rm \
        ${NETWORK_ARG} \
        -e SERVICES=s3,ssm,secretsmanager,sts,ec2 \
        -e DEBUG=0 \
        localstack/localstack:latest 2>&1)

    if [ -z "${LOCALSTACK_CONTAINER}" ] || echo "${LOCALSTACK_CONTAINER}" | grep -q "Error"; then
        die "Failed to start LocalStack: ${LOCALSTACK_CONTAINER}"
    fi

    # Wait for LocalStack to be ready
    log "Waiting for LocalStack to be ready..."
    for i in $(seq 1 60); do
        if curl -s "http://127.0.0.1:${LOCALSTACK_PORT}/_localstack/health" 2>/dev/null | grep -q '"s3"'; then
            log "LocalStack ready (container ${LOCALSTACK_CONTAINER:0:12})"

            # Run scenario-specific setup if present
            setup_script="${SCRIPT_DIR}/scenarios/${scenario_name}/localstack-setup.sh"
            if [ -f "${setup_script}" ]; then
                log "Running LocalStack setup for ${scenario_name}..."
                AWS_ENDPOINT_URL="http://127.0.0.1:${LOCALSTACK_PORT}" \
                AWS_ACCESS_KEY_ID=test \
                AWS_SECRET_ACCESS_KEY=test \
                AWS_DEFAULT_REGION=us-east-1 \
                    sh "${setup_script}" \
                    > "${INTEGRATION_OUT}/localstack-setup-${scenario_name}.log" 2>&1 || \
                    die "LocalStack setup failed for ${scenario_name}"
            fi
            return 0
        fi
        sleep 1
    done
    die "LocalStack failed to start within 60 seconds"
}

stop_localstack()
{
    if [ -n "${LOCALSTACK_CONTAINER}" ]; then
        log "Stopping LocalStack (container ${LOCALSTACK_CONTAINER:0:12})"
        docker stop "${LOCALSTACK_CONTAINER}" >/dev/null 2>&1 || true
        LOCALSTACK_CONTAINER=""
    fi
}

run_scenario()
{
    scenario_name="$1"
    scenario_dir="${SCRIPT_DIR}/scenarios/${scenario_name}"

    [ -d "${scenario_dir}" ] || die "scenario not found: ${scenario_name}"

    log "Running scenario: ${scenario_name}"

    # Track if we need to rebuild after overlay scenarios
    if [ -d "${scenario_dir}/overlay" ]; then
        # Rebuild with overlay for this scenario
        log "Rebuilding image with overlay..."
        build_test_image "${scenario_dir}"
        IMAGE_HAS_OVERLAY=1
    elif [ "${IMAGE_HAS_OVERLAY:-0}" = "1" ]; then
        # Previous scenario had overlay, rebuild base image
        log "Rebuilding base image..."
        build_test_image ""
        IMAGE_HAS_OVERLAY=0
    fi

    # Read scenario config
    nic_count=$(get_scenario_config "${scenario_name}" "NIC_COUNT" "1")
    spot_termination_delay=$(get_scenario_config "${scenario_name}" "SPOT_TERMINATION_DELAY" "0")
    use_localstack=$(get_scenario_config "${scenario_name}" "USE_LOCALSTACK" "0")

    # Start mock IMDS server for this scenario
    start_mock_imds "${scenario_name}" "${nic_count}" "${spot_termination_delay}"

    # Start LocalStack if needed
    if [ "${use_localstack}" = "1" ]; then
        start_localstack "${scenario_name}"
    fi

    # Capture serial output
    output_file="${INTEGRATION_OUT}/${scenario_name}.log"

    # Kernel command line with environment variables for init
    # - EASYTO_TEST_MODE: enables test-specific behavior (chmod /dev/ttyS0)
    # - AWS_EC2_METADATA_SERVICE_ENDPOINT: points to host-side mock IMDS
    # - AWS_ENDPOINT_URL: points to LocalStack when enabled
    kernel_cmdline="rdinit=/.easyto/sbin/init console=ttyS0 panic=-1"
    kernel_cmdline="${kernel_cmdline} EASYTO_TEST_MODE=1"
    kernel_cmdline="${kernel_cmdline} AWS_EC2_METADATA_SERVICE_ENDPOINT=http://10.0.2.2:${IMDS_PORT}"

    # Add LocalStack endpoint configuration if enabled
    if [ "${use_localstack}" = "1" ]; then
        kernel_cmdline="${kernel_cmdline} AWS_ENDPOINT_URL=http://10.0.2.2:${LOCALSTACK_PORT}"
        kernel_cmdline="${kernel_cmdline} AWS_ACCESS_KEY_ID=test"
        kernel_cmdline="${kernel_cmdline} AWS_SECRET_ACCESS_KEY=test"
        kernel_cmdline="${kernel_cmdline} AWS_REGION=us-east-1"
    fi

    # Generate NIC arguments
    nic_args=$(generate_qemu_nic_args "${nic_count}")

    # Run QEMU with timeout
    # Use -cpu max to enable SSE4.1/PCLMULQDQ required by AWS SDK's crc-fast dependency
    set +e
    if [ -n "${VERBOSE}" ]; then
        # Show output in real-time while also capturing to file
        timeout "${TIMEOUT}" qemu-system-x86_64 \
            -accel kvm -accel tcg \
            -cpu max \
            -m 512 \
            -kernel "${KERNEL}" \
            -initrd "${INITRAMFS}" \
            -append "${kernel_cmdline}" \
            -nographic \
            ${nic_args} \
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
            -cpu max \
            -m 512 \
            -kernel "${KERNEL}" \
            -initrd "${INITRAMFS}" \
            -append "${kernel_cmdline}" \
            -nographic \
            ${nic_args} \
            -no-reboot \
            > "${output_file}" 2>&1
        exit_code=$?
    fi
    set -e

    # Stop mock services
    stop_mock_imds
    stop_localstack

    # Check results
    if [ ${exit_code} -eq 124 ]; then
        log "TIMEOUT: ${scenario_name} (${TIMEOUT}s exceeded)"
        log "Log: ${output_file}"
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
            log "Log: ${output_file}"
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
        log "Log: ${output_file}"
        rm -f "${output_file}.clean"
        return 1
    else
        log "UNKNOWN: ${scenario_name} (no PASS/FAIL marker)"
        log "Log: ${output_file}"
        rm -f "${output_file}.clean"
        return 1
    fi
}

cleanup()
{
    stop_mock_imds
    stop_localstack
}

main()
{
    trap cleanup EXIT

    check_prerequisites
    build_test_image

    failed=""

    if [ -n "${SCENARIO}" ]; then
        # Run single scenario
        if ! run_scenario "${SCENARIO}"; then
            failed="${SCENARIO}"
        fi
    else
        # Run all scenarios
        for scenario_dir in "${SCRIPT_DIR}/scenarios"/*/; do
            scenario_name=$(basename "${scenario_dir}")
            if ! run_scenario "${scenario_name}"; then
                if [ -n "${failed}" ]; then
                    failed="${failed} ${scenario_name}"
                else
                    failed="${scenario_name}"
                fi
            fi
        done
    fi

    if [ -n "${failed}" ]; then
        log "Failed scenarios: ${failed}"
        log "Logs available at: ${INTEGRATION_OUT}"
        exit 1
    fi

    log "All scenarios passed"

    # Clean up temp directory on success unless KEEP_LOGS is set
    if [ -z "${KEEP_LOGS}" ]; then
        rm -rf "${INTEGRATION_OUT}"
    else
        log "Logs available at: ${INTEGRATION_OUT}"
    fi
}

main "$@"
