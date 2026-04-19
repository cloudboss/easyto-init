# Changelog

## [0.5.0] - 2026-04-19

### Changed

- Update [easyto-assets](https://github.com/cloudboss/easyto-assets) to `v0.6.0`. This includes a kernel configuration trimmed specifically for EC2 Nitro, new support for XFS, and version updates to zlib, OpenSSL, and OpenSSH.
- Update bench-qemu and integration test runner to use virtio-net-pci in QEMU.
- Update bench-qemu to run in container from Makefile.

## [0.4.1] - 2026-04-17

### Fixed

- Template should render as literal string if `variables` is either null or an empty mapping.

## [0.4.0] - 2026-04-16

The most user visible change is the addition of "template" pseudo-volumes to enable writing files from mustache templates with variable expansion or literal strings with no variables. The system was rewritten in Zig, which vastly improves compile times as well as binary size (this is largely due to not needing tokio and Rust's bloated AWS SDK), but *should* not change the behavior.

### Added

- Support for loading kernel modules in user data.
- Integration testing infrastructure using QEMU, mock IMDS server, and LocalStack.
- Set hostname from IMDS during network initialization.
- Spot instance termination monitor shuts down system gracefully.
- QEMU boot benchmarking script.
- Added "template" pseudo-volumes so files can be written from mustache templates defined in user data, or from literal strings with no variables.
- Allow user data to be gzipped.
- Write user data to a file.

### Changed

- Upgraded to easyto-assets v0.5.1.
- Updated images to pull from ghcr.io to avoid throttling.
- Full rewrite in Zig.
- Parallelize boot sequence with DAG executor.

### Fixed

- Pinned LocalStack container image version as using latest caused tests to fail.

## [0.3.0] - 2026-01-03

### Added

- Add network configuration in easyto-init as the first task, which was previously done by passing ip=dhcp to the kernel. This enables stable interface names on instances that might have more than one ENI, such as Kubernetes nodes.

### Changed

- Convert to the official AWS SDK from the `minaws` crate. This required adding tokio as a dependency.
- Replace simple_logger with an internal implementation that can change the log level at runtime. This is so logging can occur before user data is read, and the log level can be set to what is defined in user data.

### Fixed

- Fix handling of IAM credentials and user data. If user data is not defined, it should not be an error. Similarly with no instance profile, unless the user data is configured to require one.
- When running EBS volume attachment, check if the volume is already attached, otherwise it would wait for the volume to be available until timeout.

## [0.2.0] - 2025-10-15

### Added

- Add EBS volume attachment. EBS volumes can now be attached upon boot based on their tags. The instance must have an instance profile with a policy allowing `ec2:AttachVolume` and `ec2:DescribeVolumes` actions.

### Changed

- Build is updated to use Rust `1.90.0`.
- Multiple dependencies were updated for security advisories.

### Removed

- `serde_yml` was removed and replaced with `serde_yaml2`.

## [0.1.1] - 2024-11-10

### Changed

- Modify release artifact to be in sync with https://github.com/cloudboss/easyto-assets artifacts.

## [0.1.0] - 2024-11-09

Initial release

[0.5.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.5.0
[0.4.1]: https://github.com/cloudboss/easyto-init/releases/tag/v0.4.1
[0.4.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.4.0
[0.3.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.3.0
[0.2.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.2.0
[0.1.1]: https://github.com/cloudboss/easyto-init/releases/tag/v0.1.1
[0.1.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.1.0
