const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    // Dependencies
    const aws_sdk_dep = b.dependency("aws_sdk", .{ .target = target, .optimize = optimize });
    const dhcpz_dep = b.dependency("dhcpz", .{ .target = target });
    const k8s_expand_dep = b.dependency("k8s_expand", .{ .target = target, .optimize = optimize });
    const nlz_dep = b.dependency("nlz", .{ .target = target, .optimize = optimize });
    const yaml_dep = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const zgpt_dep = b.dependency("zgpt", .{ .target = target, .optimize = optimize });
    const zblkpg_dep = b.dependency("zblkpg", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("easyto_init", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "aws", .module = aws_sdk_dep.module("aws") },
            .{ .name = "s3", .module = aws_sdk_dep.module("s3") },
            .{ .name = "ssm", .module = aws_sdk_dep.module("ssm") },
            .{ .name = "secretsmanager", .module = aws_sdk_dep.module("secretsmanager") },
            .{ .name = "ec2", .module = aws_sdk_dep.module("ec2") },
            .{ .name = "dhcpz", .module = dhcpz_dep.module("dhcpz") },
            .{ .name = "k8s_expand", .module = k8s_expand_dep.module("k8s_expand") },
            .{ .name = "nlz", .module = nlz_dep.module("nlz") },
            .{ .name = "yaml", .module = yaml_dep.module("yaml") },
            .{ .name = "zgpt", .module = zgpt_dep.module("zgpt") },
            .{ .name = "zblkpg", .module = zblkpg_dep.module("zblkpg") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aws", .module = aws_sdk_dep.module("aws") },
                .{ .name = "s3", .module = aws_sdk_dep.module("s3") },
                .{ .name = "ssm", .module = aws_sdk_dep.module("ssm") },
                .{ .name = "secretsmanager", .module = aws_sdk_dep.module("secretsmanager") },
                .{ .name = "ec2", .module = aws_sdk_dep.module("ec2") },
                .{ .name = "dhcpz", .module = dhcpz_dep.module("dhcpz") },
                .{ .name = "easyto_init", .module = mod },
                .{ .name = "k8s_expand", .module = k8s_expand_dep.module("k8s_expand") },
                .{ .name = "nlz", .module = nlz_dep.module("nlz") },
                .{ .name = "yaml", .module = yaml_dep.module("yaml") },
                .{ .name = "zgpt", .module = zgpt_dep.module("zgpt") },
                .{ .name = "zblkpg", .module = zblkpg_dep.module("zblkpg") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
