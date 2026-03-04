//! AWS context providing lazily-initialized clients for AWS services.

const std = @import("std");
const Allocator = std.mem.Allocator;

const aws = @import("aws");

const Ec2Client = @import("ec2.zig").Ec2Client;
const S3Client = @import("s3.zig").S3Client;
const SecretsManagerClient = @import("asm.zig").SecretsManagerClient;
const SsmClient = @import("ssm.zig").SsmClient;

const scoped_log = std.log.scoped(.aws_context);

pub const AwsContext = struct {
    allocator: Allocator,

    imds: aws.ImdsClient,
    region: ?[]const u8 = null,
    credentials_verified: bool = false,
    ec2: ?Ec2Client = null,
    s3: ?S3Client = null,
    ssm: ?SsmClient = null,
    secrets_manager: ?SecretsManagerClient = null,

    const Self = @This();

    pub const Error = error{
        /// No IAM instance profile attached to the instance.
        NoInstanceProfile,
    };

    /// Initialize the AWS context with an IMDS client.
    pub fn init(allocator: Allocator) !Self {
        const imds = try aws.ImdsClient.init(allocator, .{});

        return Self{
            .allocator = allocator,
            .imds = imds,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.ec2) |*client| {
            client.deinit();
        }
        if (self.s3) |*client| {
            client.deinit();
        }
        if (self.ssm) |*client| {
            client.deinit();
        }
        if (self.secrets_manager) |*client| {
            client.deinit();
        }
        if (self.region) |region| self.allocator.free(region);
        self.imds.deinit();
    }

    /// Get the IMDS client.
    pub fn getImds(self: *Self) *aws.ImdsClient {
        return &self.imds;
    }

    /// Get or initialize the S3 client.
    /// Returns error if no IAM instance profile is attached.
    pub fn getS3(self: *Self) !*S3Client {
        try self.verifyCredentials();
        if (self.s3 == null) {
            self.s3 = try S3Client.init(self.allocator, self.region.?);
        }
        return &self.s3.?;
    }

    /// Get or initialize the SSM client.
    /// Returns error if no IAM instance profile is attached.
    pub fn getSsm(self: *Self) !*SsmClient {
        try self.verifyCredentials();
        if (self.ssm == null) {
            self.ssm = try SsmClient.init(self.allocator, self.region.?);
        }
        return &self.ssm.?;
    }

    /// Get or initialize the Secrets Manager client.
    /// Returns error if no IAM instance profile is attached.
    pub fn getSecretsManager(self: *Self) !*SecretsManagerClient {
        try self.verifyCredentials();
        if (self.secrets_manager == null) {
            self.secrets_manager = try SecretsManagerClient.init(
                self.allocator,
                self.region.?,
            );
        }
        return &self.secrets_manager.?;
    }

    /// Get or initialize the EC2 client.
    /// Returns error if no IAM instance profile is attached.
    pub fn getEc2(self: *Self) !*Ec2Client {
        try self.verifyCredentials();
        if (self.ec2 == null) {
            self.ec2 = try Ec2Client.init(self.allocator, self.region.?);
        }
        return &self.ec2.?;
    }

    fn verifyCredentials(self: *Self) !void {
        if (self.credentials_verified) return;
        try self.resolveRegion();
        var creds = self.imds.getIamCredentials(.{}) catch |err| {
            scoped_log.err(
                "user data config requires an IAM instance profile: {s}",
                .{@errorName(err)},
            );
            return Error.NoInstanceProfile;
        };
        creds.deinit();
        self.credentials_verified = true;
    }

    fn resolveRegion(self: *Self) !void {
        if (self.region != null) return;
        const region = self.imds.getMetadata(
            "/latest/meta-data/placement/region",
            .{},
        ) catch |err| {
            scoped_log.err("failed to get region from IMDS: {s}", .{@errorName(err)});
            return err;
        };
        scoped_log.info("AWS region: {s}", .{region});
        self.region = region;
    }
};
