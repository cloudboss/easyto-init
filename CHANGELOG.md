# Changelog

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

[0.2.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.2.0
[0.1.1]: https://github.com/cloudboss/easyto-init/releases/tag/v0.1.1
[0.1.0]: https://github.com/cloudboss/easyto-init/releases/tag/v0.1.0
