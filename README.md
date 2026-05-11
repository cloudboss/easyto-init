# easyto-init

The init system for [easyto](https://github.com/cloudboss/easyto).

This is PID 1 inside an easyto-built AMI. On boot, it:
- Mounts the early filesystems (`/`, `devtmpfs`, `proc`, `sysfs`, `cgroup2`, etc).
- Reads container metadata baked into the AMI, derived from the container image the AMI was built from. This contains the default command or entrypoint, environment variables, working directory, etc.
- Brings up networking on the primary EC2 interface.
- Retrieves the instance's user data from IMDS. The user data can contain overrides for the container metadata and other configuration, such as external sources for environment variables and files.
- Resolves environment variables or files from S3, SSM, or Secrets Manager.
- Formats and mounts any configured EBS volumes. Optionally, it will first attach external EBS volumes that match specified tags.
- Loads kernel modules.
- Sets sysctls.
- Runs init scripts defined in user data.
- Runs the configured command as a process supervised by easyto-init, or via execve() (by setting `replace-init: true` in user data). Note that the latter option will not perform a clean shutdown when the EC2 instance is terminated unless your command knows how to do so.

The user data is a YAML document that can be seen under `tests/integration/scenarios/`; see `basic-boot` for the smallest example and `env-from-imds` or `secrets-manager-env-from` for environment variable resolution from AWS sources.

## Building

```
make build
make release VERSION=v0.x.y
```

## Testing

```
make test                                      # Run unit tests.
make test-integration-kvm                      # Run the full integration test suite.
make test-integration-kvm SCENARIO=basic-boot  # Run one integration scenario.
```

Integration tests run scenarios inside QEMU/KVM with a mock IMDS
server and (where needed) LocalStack for S3/SSM/Secrets Manager.
