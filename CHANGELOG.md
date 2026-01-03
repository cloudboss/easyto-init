# Changelog

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

[0.3.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.3.0
[0.2.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.2.0
[0.1.1]: https://github.com/cloudboss/easyto-init/releases/tag/v0.1.1
[0.1.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.1.0
