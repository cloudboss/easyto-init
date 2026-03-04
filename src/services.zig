const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const testing = std.testing;

const aws = @import("aws");

const constants = @import("constants.zig");
const fs_utils = @import("fs.zig");
const login = @import("login.zig");

pub const ServiceDef = struct {
    name: []const u8,
    args: []const []const u8,
    optional: bool = false,
    init_fn: ?*const fn (Allocator) anyerror!void = null,
};

/// Context for SSH service initialization, stored globally since init_fn cannot take extra args.
var ssh_pub_key: ?[]const u8 = null;
var ssh_pub_key_allocator: ?Allocator = null;

/// Free any globally allocated service state.
pub fn deinit() void {
    if (ssh_pub_key) |key| {
        if (ssh_pub_key_allocator) |alloc| {
            alloc.free(key);
        }
    }
    ssh_pub_key = null;
    ssh_pub_key_allocator = null;
}

/// Initialize the chrony service.
/// Creates the run directory and sets ownership to the chrony user.
pub fn initChrony(allocator: Allocator) !void {
    std.log.info("initializing chrony", .{});

    const passwd_contents = fs_utils.readFileAlloc(allocator, constants.FILE_ETC_PASSWD) catch |err| {
        std.log.err("failed to read {s}: {s}", .{ constants.FILE_ETC_PASSWD, @errorName(err) });
        return err;
    };
    defer allocator.free(passwd_contents);

    const uid = login.user_group_id(passwd_contents, constants.USER_NAME_CHRONY) catch |err| {
        std.log.err("user {s} not found: {s}", .{ constants.USER_NAME_CHRONY, @errorName(err) });
        return err;
    };

    const group_contents = fs_utils.readFileAlloc(allocator, constants.FILE_ETC_GROUP) catch |err| {
        std.log.err("failed to read {s}: {s}", .{ constants.FILE_ETC_GROUP, @errorName(err) });
        return err;
    };
    defer allocator.free(group_contents);

    const gid = login.user_group_id(group_contents, constants.USER_NAME_CHRONY) catch uid;

    // Create chrony run directory with correct ownership
    const chrony_run_path = constants.DIR_ET_RUN ++ "/chrony";
    try fs_utils.mkdir_p_own(chrony_run_path, 0o750, uid, gid);
}

/// Initialize the SSH service.
/// - Writes the SSH public key to the login user's authorized_keys file
/// - Generates host keys if they don't exist
pub fn initSsh(allocator: Allocator) !void {
    std.log.info("initializing sshd", .{});

    const pub_key = ssh_pub_key orelse {
        std.log.err("SSH public key not set", .{});
        return error.SshPubKeyNotSet;
    };

    // Get the login user (single directory under /.easyto/home)
    const login_user_buf = getLoginUser() catch |err| {
        std.log.err("failed to get login user: {s}", .{@errorName(err)});
        return err;
    };
    const login_user = std.mem.sliceTo(&login_user_buf, 0);

    // Read passwd file to get user's home directory
    const passwd_contents = fs_utils.readFileAlloc(allocator, constants.FILE_ETC_PASSWD) catch |err| {
        std.log.err("failed to read {s}: {s}", .{ constants.FILE_ETC_PASSWD, @errorName(err) });
        return err;
    };
    defer allocator.free(passwd_contents);

    const user_entry = login.getUserEntry(passwd_contents, login_user) catch |err| {
        std.log.err("user {s} not found in passwd: {s}", .{ login_user, @errorName(err) });
        return err;
    };

    // Write authorized_keys file
    try writeAuthorizedKeys(allocator, user_entry.home_dir, user_entry.uid, user_entry.gid, pub_key);

    // Generate host keys if missing
    try generateHostKeysIfMissing(allocator);
}

fn getLoginUser() ![64]u8 {
    var dir = std.fs.openDirAbsolute(constants.DIR_ET_HOME, .{ .iterate = true }) catch |err| {
        std.log.err("failed to open {s}: {s}", .{ constants.DIR_ET_HOME, @errorName(err) });
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        // Found the login user directory
        var buf: [64]u8 = undefined;
        if (entry.name.len > buf.len) {
            return error.UserNameTooLong;
        }
        @memcpy(buf[0..entry.name.len], entry.name);
        // Fill the rest with zeros for consistent comparison
        @memset(buf[entry.name.len..], 0);
        return buf;
    }

    return error.LoginUserNotFound;
}

fn writeAuthorizedKeys(allocator: Allocator, home_dir: []const u8, uid: u32, gid: u32, pub_key: []const u8) !void {
    // Build path: home_dir/.ssh/authorized_keys
    const ssh_dir = try std.fmt.allocPrint(allocator, "{s}/.ssh", .{home_dir});
    defer allocator.free(ssh_dir);

    const auth_keys_path = try std.fmt.allocPrint(allocator, "{s}/authorized_keys", .{ssh_dir});
    defer allocator.free(auth_keys_path);

    // Create .ssh directory if needed
    try fs_utils.mkdir_p_own(ssh_dir, 0o700, uid, gid);

    // Write authorized_keys file
    try fs_utils.writeFile(auth_keys_path, pub_key, 0o640, 0o700, uid, gid);

    std.log.info("wrote SSH authorized_keys to {s}", .{auth_keys_path});
}

fn generateHostKeysIfMissing(allocator: Allocator) !void {
    const ssh_keygen_path = constants.DIR_ET_BIN ++ "/ssh-keygen";
    const ssh_etc_dir = constants.DIR_ET_ETC ++ "/ssh";

    // Check and generate RSA key
    const rsa_key_path = ssh_etc_dir ++ "/ssh_host_rsa_key";
    if (!fileExists(rsa_key_path)) {
        try runSshKeygen(allocator, ssh_keygen_path, "rsa", rsa_key_path);
    }

    // Check and generate ED25519 key
    const ed25519_key_path = ssh_etc_dir ++ "/ssh_host_ed25519_key";
    if (!fileExists(ed25519_key_path)) {
        try runSshKeygen(allocator, ssh_keygen_path, "ed25519", ed25519_key_path);
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn runSshKeygen(allocator: Allocator, keygen_path: []const u8, key_type: []const u8, key_path: []const u8) !void {
    std.log.info("generating SSH host key: {s}", .{key_path});

    var child = std.process.Child.init(
        &[_][]const u8{ keygen_path, "-t", key_type, "-f", key_path, "-N", "" },
        allocator,
    );

    _ = child.spawnAndWait() catch |err| {
        std.log.err("failed to run ssh-keygen: {s}", .{@errorName(err)});
        return err;
    };
}

/// Chrony service definition
pub const chrony_service = ServiceDef{
    .name = "chrony",
    .args = &[_][]const u8{ constants.DIR_ET_SBIN ++ "/chronyd", "-d" },
    .init_fn = initChrony,
};

/// SSH service definition
pub const ssh_service = ServiceDef{
    .name = "ssh",
    .args = &[_][]const u8{
        constants.DIR_ET_SBIN ++ "/sshd",
        "-D",
        "-f",
        constants.DIR_ET_ETC ++ "/ssh/sshd_config",
        "-e",
    },
    .optional = true,
    .init_fn = initSsh,
};

/// Find enabled services by scanning the services directory.
/// The imds_client is optional; if provided and SSH service exists, it will
/// fetch the SSH public key from IMDS.
pub fn findEnabledServices(
    allocator: Allocator,
    disable_services: ?[]const []const u8,
    imds_client: ?*aws.ImdsClient,
) ![]const ServiceDef {
    var enabled = try std.ArrayList(ServiceDef).initCapacity(allocator, 4);
    errdefer enabled.deinit(allocator);

    var dir = std.fs.openDirAbsolute(constants.DIR_ET_SERVICES, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("no services directory found, skipping service discovery", .{});
            return try enabled.toOwnedSlice(allocator);
        }
        std.log.err("failed to open services directory: {s}", .{@errorName(err)});
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        // Check if service is disabled
        if (isServiceDisabled(entry.name, disable_services)) {
            std.log.info("disabling service {s}", .{entry.name});
            continue;
        }

        // Match known services
        if (std.mem.eql(u8, entry.name, "chrony")) {
            try enabled.append(allocator, chrony_service);
        } else if (std.mem.eql(u8, entry.name, "ssh")) {
            // SSH service requires IMDS to fetch the public key
            if (imds_client) |imds| {
                if (try fetchSshPubKey(allocator, imds)) |key| {
                    // Store the key globally for initSsh to use
                    ssh_pub_key = key;
                    ssh_pub_key_allocator = allocator;
                    try enabled.append(allocator, ssh_service);
                } else {
                    std.log.info("disabling service ssh as no public key was assigned", .{});
                }
            } else {
                std.log.warn("SSH service found but IMDS client not available, skipping", .{});
            }
        } else {
            std.log.warn("unknown service {s}", .{entry.name});
        }
    }

    return try enabled.toOwnedSlice(allocator);
}

fn fetchSshPubKey(allocator: Allocator, imds: *aws.ImdsClient) !?[]const u8 {
    var diagnostic: aws.imds.ServiceError = undefined;
    const key = imds.getMetadata(
        "/latest/meta-data/public-keys/0/openssh-key",
        .{ .diagnostic = &diagnostic },
    ) catch |err| {
        if (err == error.HttpError and diagnostic.httpStatus() == 404) {
            return null;
        }
        std.log.err("failed to fetch SSH public key from IMDS: {s}", .{@errorName(err)});
        return err;
    };

    // Store in allocator-owned memory
    const owned_key = try allocator.dupe(u8, key);
    allocator.free(key);
    return owned_key;
}

fn isServiceDisabled(name: []const u8, disable_services: ?[]const []const u8) bool {
    const disabled = disable_services orelse return false;
    for (disabled) |disabled_name| {
        if (std.mem.eql(u8, name, disabled_name)) {
            return true;
        }
    }
    return false;
}

test "isServiceDisabled returns false for null list" {
    try testing.expect(!isServiceDisabled("chrony", null));
}

test "isServiceDisabled returns false when not in list" {
    const disabled = [_][]const u8{ "ssh", "network" };
    try testing.expect(!isServiceDisabled("chrony", &disabled));
}

test "isServiceDisabled returns true when in list" {
    const disabled = [_][]const u8{ "ssh", "chrony", "network" };
    try testing.expect(isServiceDisabled("chrony", &disabled));
}

test "isServiceDisabled returns true for exact match" {
    const disabled = [_][]const u8{"chrony"};
    try testing.expect(isServiceDisabled("chrony", &disabled));
    try testing.expect(!isServiceDisabled("chrony2", &disabled));
}

test "chrony_service has correct definition" {
    try testing.expectEqualStrings("chrony", chrony_service.name);
    try testing.expect(!chrony_service.optional);
    try testing.expect(chrony_service.init_fn != null);
}

test "ssh_service has correct definition" {
    try testing.expectEqualStrings("ssh", ssh_service.name);
    try testing.expect(ssh_service.optional);
    try testing.expect(ssh_service.init_fn != null);
    try testing.expectEqual(@as(usize, 5), ssh_service.args.len);
}
