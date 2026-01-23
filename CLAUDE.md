# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an init system for EC2 instances whose AMI was built from a container image using the `easyto` tool. These instances do not have systemd or udev; this project provides the minimal replacement. The init system can operate in two modes:
- **Supervisor mode** (default): Long-running process that supervises the entrypoint and services
- **Replace mode**: Calls `execve()` to replace itself with the entrypoint (configured via `replace-init: true` in user data)

The system reads a VMspec from EC2 user data (YAML format) which combines container configuration (ENTRYPOINT, USER, ENV from Dockerfile) with easyto-specific features like S3 file retrieval, Secrets Manager/SSM Parameter Store integration, and EBS volume attachment.

## Build Commands

```bash
# Build the release binary (runs in Docker with musl target)
make release VERSION=v0.3.0

# Run tests and clippy lints
make test

# Run integration tests (requires Docker, uses QEMU)
make test-integration-kvm

# Run integration tests with real-time console output
make test-integration-kvm VERBOSE=1

# Clean build artifacts
make clean
```

The build uses Docker with `rust:1.90.0-alpine3.22` to produce a statically-linked musl binary for `x86_64-unknown-linux-musl`. Output goes to `_output/`.

## Architecture

### Initialization Flow (`src/init.rs`)

1. Set SSL_CERT_FILE, initialize logger
2. Create tokio runtime and AWS context
3. Initialize network via DHCP
4. Parse user data from IMDS into `UserData`, merge with container config to create `VmSpec`
5. Load kernel modules, set sysctls
6. Mount base filesystems (/dev, /proc, /sys, etc.)
7. Process volumes (EBS, S3, Secrets Manager, SSM)
8. Resolve environment variables from external sources
9. Run init scripts
10. Either `execve()` the entrypoint (replace mode) or start supervisor

### Key Types

- **`VmSpec`** (`src/vmspec.rs`): Runtime configuration combining container config with user data. Contains command, args, env, volumes, security settings, services to disable, etc.
- **`UserData`** (`src/vmspec.rs`): YAML schema for EC2 user data. Uses kebab-case field names.
- **`Supervisor`** (`src/service.rs`): Manages the main process and services (chrony, ssh). Handles SIGPOWEROFF for graceful shutdown.

### AWS Clients (`src/aws/`)

Lazy-initialized clients wrapped in `AwsCtx`:
- `imds`: EC2 Instance Metadata Service
- `ec2`: EBS volume attachment
- `s3`: File retrieval
- `ssm`: Parameter Store
- `asm`: Secrets Manager

### Services (`src/service.rs`)

Built-in services discovered from `/.easyto/services/`:
- **chrony**: NTP daemon
- **ssh**: SSH daemon (optional, requires public key in IMDS)

Services auto-restart on failure. The supervisor waits for SIGPOWEROFF or main process exit, then sends SIGTERM to all processes with a configurable grace period.

### File Layout on Target

All easyto-specific files live under `/.easyto/`:
- `/.easyto/bin/` - Utilities (sh, ssh-keygen)
- `/.easyto/sbin/` - Init and service binaries (chronyd, sshd, mkfs.*)
- `/.easyto/etc/` - Config files (amazon.pem, ssh/)
- `/.easyto/run/` - Runtime data (tmpfs)
- `/.easyto/services/` - Service discovery directory
- `/.easyto/metadata.json` - Container config from image build

## Integration Tests

Integration tests run the init binary in QEMU with a mock IMDS server. Located in `tests/integration/`:

- `run.sh` - Test runner, iterates over scenarios
- `image/build.sh` - Builds test initramfs with Alpine + Python
- `image/init-wrapper` - Sets up mock environment before running init
- `image/test-entrypoint` - Default test script that verifies boot succeeded
- `mocks/imds_server.py` - Python HTTP server supporting IMDSv2 (PUT for token, GET for metadata)
- `scenarios/*/` - Individual test scenarios with optional `user-data.yaml`

The init-wrapper:
1. Mounts /proc, /sys, /dev
2. Configures loopback with 169.254.169.254 for IMDS
3. Creates mock IMDS data structure in /tmp/imds
4. Starts Python mock IMDS server
5. Creates persisted network state to skip interface discovery
6. Execs the real init binary

Tests output PASS/FAIL to serial console. The runner checks for these markers.

## Code Style

- Avoid placeholder comments when removing code
- Comments should explain "why", not "what"
- Keep commentary technical and concise
- Do not use the `libc` crate; use `rustix` instead for system calls
- Prefer imports over fully qualified names at call sites (e.g., `use anyhow::Result` and `Result<T>` instead of `anyhow::Result<T>`)
- Rust code must be formatted with `rustfmt --edition 2024`

### Shell Scripts

- Use plain `/bin/sh`, not bash
- Always use curly braces for variable expansion: `${VAR}` not `$VAR`
- Place opening brace on the line after the function name:
  ```sh
  my_func()
  {
      ...
  }
  ```
