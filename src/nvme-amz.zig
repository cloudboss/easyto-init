const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const string = @import("string.zig");

const AMZ_EBS_MN = "Amazon Elastic Block Store";
const AMZ_INST_STORE_MN = "Amazon EC2 NVMe Instance Storage";
const AMZ_VENDOR_ID: c_ushort = 0x1D0F;
const NVME_ADMIN_IDENTIFY: u8 = 0x06;
const NVME_IOCTL_ADMIN_CMD_NUM: u8 = 0x41;

const Error = error{
    IoctlError,
    NoDeviceName,
    UnknownModelNumber,
    UnknownVendorId,
};

const NvmeIdPsd = extern struct {
    mp: c_ushort,
    rsvd2: u8,
    flags: u8,
    enlat: c_uint,
    exlat: c_uint,
    rrt: u8,
    rrl: u8,
    rwt: u8,
    rwl: u8,
    idlp: c_ushort,
    ips: u8,
    rsvd19: u8,
    actp: c_ushort,
    apws: u8,
    rsvd23: [9]u8,
};

const NvmeVuIdCtrlField = extern struct {
    bdev: [32]u8,
    reserved0: [992]u8,
};

const NvmeIdCtrl = extern struct {
    vid: c_ushort,
    ssvid: c_ushort,
    sn: [20]i8,
    mn: [40]i8,
    fr: [8]i8,
    rab: u8,
    ieee: [3]u8,
    cmic: u8,
    mdts: u8,
    cntlid: c_ushort,
    ver: c_uint,
    rtd3r: c_uint,
    rtd3e: c_uint,
    oaes: c_uint,
    ctratt: c_uint,
    rrls: c_ushort,
    rsvd102: [9]u8,
    cntrltype: u8,
    fguid: [16]u8,
    crdt1: c_ushort,
    crdt2: c_ushort,
    crdt3: c_ushort,
    rsvd134: [119]u8,
    nvmsr: u8,
    vwci: u8,
    mec: u8,
    oacs: c_ushort,
    acl: u8,
    aerl: u8,
    frmw: u8,
    lpa: u8,
    elpe: u8,
    npss: u8,
    avscc: u8,
    apsta: u8,
    wctemp: c_ushort,
    cctemp: c_ushort,
    mtfa: c_ushort,
    hmpre: c_uint,
    hmmin: c_uint,
    tnvmcap: [16]u8,
    unvmcap: [16]u8,
    rpmbs: c_uint,
    edstt: c_ushort,
    dsto: u8,
    fwug: u8,
    kas: c_ushort,
    hctma: c_ushort,
    mntmt: c_ushort,
    mxtmt: c_ushort,
    sanicap: c_uint,
    hmminds: c_uint,
    hmmaxd: c_ushort,
    nsetidmax: c_ushort,
    endgidmax: c_ushort,
    anatt: u8,
    anacap: u8,
    anagrpmax: c_uint,
    nanagrpid: c_uint,
    pels: c_uint,
    domainid: c_ushort,
    rsvd358: [10]u8,
    megcap: [16]u8,
    tmpthha: u8,
    rsvd385: [127]u8,
    sqes: u8,
    cqes: u8,
    maxcmd: c_ushort,
    nn: c_uint,
    oncs: c_ushort,
    fuses: c_ushort,
    fna: u8,
    vwc: u8,
    awun: c_ushort,
    awupf: c_ushort,
    icsvscc: u8,
    nwpc: u8,
    acwu: c_ushort,
    ocfs: c_ushort,
    sgls: c_uint,
    mnan: c_uint,
    maxdna: [16]u8,
    maxcna: c_uint,
    oaqd: c_uint,
    rsvd568: [200]u8,
    subnqn: [256]i8,
    rsvd1024: [768]u8,
    ioccsz: c_uint,
    iorcsz: c_uint,
    icdoff: c_ushort,
    fcatt: u8,
    msdbd: u8,
    ofcs: c_ushort,
    dctype: u8,
    rsvd1807: [241]u8,
    psd: [32]NvmeIdPsd,
    vs: NvmeVuIdCtrlField,
};

const NvmePassthruCmd = extern struct {
    opcode: u8,
    flags: u8,
    rsvd1: c_ushort,
    nsid: c_uint,
    cdw2: c_uint,
    cdw3: c_uint,
    metadata: c_ulonglong,
    addr: c_ulonglong,
    metadata_len: c_uint,
    data_len: c_uint,
    cdw10: c_uint,
    cdw11: c_uint,
    cdw12: c_uint,
    cdw13: c_uint,
    cdw14: c_uint,
    cdw15: c_uint,
    timeout_ms: c_uint,
    result: c_uint,
};

pub fn nvme_identify_ctrl(fd: std.posix.fd_t, errno: *usize) !NvmeIdCtrl {
    const request = std.os.linux.IOCTL.IOWR('N', NVME_IOCTL_ADMIN_CMD_NUM, NvmePassthruCmd);
    var out = std.mem.zeroInit(NvmeIdCtrl, .{});
    var arg = std.mem.zeroInit(NvmePassthruCmd, .{
        .addr = @intFromPtr(&out),
        .cdw10 = 1,
        .data_len = @sizeOf(NvmeIdCtrl),
        .opcode = NVME_ADMIN_IDENTIFY,
    });
    const ret = std.os.linux.ioctl(fd, request, @intFromPtr(&arg));
    switch (std.posix.errno(ret)) {
        .SUCCESS => {},
        else => {
            errno.* = @intFromEnum(std.posix.errno(ret));
            return Error.IoctlError;
        },
    }
    return out;
}

/// A structure containing vendor-specific device names.
pub const Names = struct {
    /// Device name defined in the block device mapping.
    device_name: ?[]const u8,
    /// Virtual name for instance store volumes, such as ephemeral0.
    virtual_name: ?[]const u8,

    pub fn from_string(allocator: Allocator, str: []const u8) !Names {
        const COLON: u8 = 0x3a;
        const SPACE: u8 = 0x20;
        const NULL: u8 = 0x0;

        var field1_start: usize = 0;
        var field1_end: usize = 0;
        var field2_start: usize = 0;
        var field2_end: usize = 0;
        var has_delim = false;

        for (str, 0..) |c, i| {
            if ((c == NULL) or (c == SPACE)) {
                break;
            }
            if (c == COLON) {
                has_delim = true;
                field2_start = i + 1;
                continue;
            }
            if (!has_delim) {
                field1_end = i + 1;
            } else {
                field2_end = i + 1;
            }
        }

        if (field1_end == 0) {
            return Error.NoDeviceName;
        }

        if (string.starts_with(str[field1_start..], "/dev")) {
            field1_start = 5;
        }

        if ((field2_start > 0) and (string.starts_with(str[field2_start..], "/dev"))) {
            field2_start += 5;
        }

        var virtual_name: ?[]const u8 = null;
        if (has_delim) {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, str[field1_start..field1_end]);
            virtual_name = try buf.toOwnedSlice(allocator);
        }

        var device_name: ?[]const u8 = null;
        if (has_delim) {
            if (!string.equals(str[field2_start..field2_end], "none")) {
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(allocator);
                try buf.appendSlice(allocator, str[field2_start..field2_end]);
                device_name = try buf.toOwnedSlice(allocator);
            }
        } else {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, str[field1_start..field1_end]);
            device_name = try buf.toOwnedSlice(allocator);
        }

        return Names{
            .device_name = device_name,
            .virtual_name = virtual_name,
        };
    }

    pub fn deinit(self: *Names, allocator: Allocator) void {
        if (self.device_name) |dn| allocator.free(dn);
        if (self.virtual_name) |vn| allocator.free(vn);
    }

    pub fn format(
        self: Names,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.print("{s}{{ .device_name = ", .{@typeName(Names)});
        _ = try writer.print("{?s}", .{self.device_name});
        try writer.writeAll(", .virtual_name = ");
        _ = try writer.print("{?s}", .{self.virtual_name});
        try writer.writeAll(" }");
    }
};

/// The model of the NVMe device.
pub const Model = enum {
    /// Elastic Block Store volume.
    AmazonElasticBlockStore,
    /// Instance store volume.
    AmazonInstanceStore,
};

fn parseModel(mn: *const [40]u8) Error!Model {
    const trimmed = std.mem.trimRight(u8, mn, &.{ ' ', 0 });
    if (std.mem.eql(u8, trimmed, AMZ_EBS_MN)) {
        return .AmazonElasticBlockStore;
    } else if (std.mem.eql(u8, trimmed, AMZ_INST_STORE_MN)) {
        return .AmazonInstanceStore;
    } else {
        return Error.UnknownModelNumber;
    }
}

/// An NVMe device, containing a subset of all identifying information.
pub const Nvme = struct {
    /// The [model](Model) of the device.
    model: Model,
    /// The [structure](Names) containing vendor-specific device names.
    names: Names,
    /// The [vendor ID](VendorId) of the device.
    vendor_id: u16,

    pub fn from_fd(allocator: Allocator, fd: std.posix.fd_t, errno: *usize) !Nvme {
        const ctrl = try nvme_identify_ctrl(fd, errno);
        if (ctrl.vid != AMZ_VENDOR_ID) {
            return Error.UnknownVendorId;
        }

        var mn: [40]u8 = undefined;
        for (ctrl.mn, 0..) |c, i| {
            mn[i] = @intCast(c);
        }
        const model = try parseModel(&mn);

        const names = try Names.from_string(allocator, &ctrl.vs.bdev);

        return Nvme{
            .model = model,
            .names = names,
            .vendor_id = ctrl.vid,
        };
    }

    pub fn name(self: Nvme) ![]const u8 {
        return self.names.device_name orelse self.names.virtual_name orelse Error.NoDeviceName;
    }

    pub fn deinit(self: *Nvme, allocator: Allocator) void {
        self.names.deinit(allocator);
    }

    pub fn format(
        self: Nvme,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.print("{s}{{ .model = ", .{@typeName(Nvme)});
        _ = try writer.print("{any}", .{self.model});
        try writer.writeAll(", .names = ");
        _ = try writer.print("{any}", .{self.names});
        try writer.writeAll(", .vendor_id = ");
        _ = try writer.print("{any}", .{self.vendor_id});
        try writer.writeAll(" }");
    }
};

test "parse nvme names empty" {
    const allocator = testing.allocator;
    const names = Names.from_string(allocator, "");

    try testing.expectError(Error.NoDeviceName, names);
}

test "parse nvme names without virtual_name" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "/dev/sda1");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.device_name.?, "sda1"));
    try testing.expect(names.virtual_name == null);
}

test "parse nvme names without virtual_name including spaces" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "/dev/sda1    ");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.device_name.?, "sda1"));
    try testing.expect(names.virtual_name == null);
}

test "parse nvme names without virtual_name without /dev" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "sda1");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.device_name.?, "sda1"));
    try testing.expect(names.virtual_name == null);
}

test "parse nvme names without virtual_name without /dev including spaces" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "sda1    ");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.device_name.?, "sda1"));
    try testing.expect(names.virtual_name == null);
}

test "parse nvme names with virtual_name" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "ephemeral0:/dev/sdf");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.device_name.?, "sdf"));
    try testing.expect(string.equals(names.virtual_name.?, "ephemeral0"));
}

test "parse nvme names with virtual_name including spaces" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "ephemeral0:/dev/sdf    ");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.device_name.?, "sdf"));
    try testing.expect(string.equals(names.virtual_name.?, "ephemeral0"));
}

test "parse nvme names with virtual_name without /dev" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "ephemeral0:sdf");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.device_name.?, "sdf"));
    try testing.expect(string.equals(names.virtual_name.?, "ephemeral0"));
}

test "parse nvme names with virtual_name without /dev including spaces" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "ephemeral0:sdf   ");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.device_name.?, "sdf"));
    try testing.expect(string.equals(names.virtual_name.?, "ephemeral0"));
}

test "parse nvme names with virtual_name with device_name none" {
    const allocator = testing.allocator;
    var names = try Names.from_string(allocator, "ephemeral0:none");
    defer names.deinit(allocator);

    try testing.expect(string.equals(names.virtual_name.?, "ephemeral0"));
    try testing.expect(names.device_name == null);
}

test "nvme struct no names" {
    const nvme = Nvme{
        .model = Model.AmazonElasticBlockStore,
        .names = Names{
            .device_name = null,
            .virtual_name = null,
        },
        .vendor_id = AMZ_VENDOR_ID,
    };
    try testing.expectError(
        Error.NoDeviceName,
        nvme.name(),
    );
}

test "nvme struct only device_name" {
    const nvme = Nvme{
        .model = Model.AmazonElasticBlockStore,
        .names = Names{
            .device_name = "nvme0n1",
            .virtual_name = null,
        },
        .vendor_id = AMZ_VENDOR_ID,
    };
    try testing.expect(string.equals(try nvme.name(), "nvme0n1"));
}

test "nvme struct only virtual_name" {
    const nvme = Nvme{
        .model = Model.AmazonElasticBlockStore,
        .names = Names{
            .device_name = null,
            .virtual_name = "ephemeral0",
        },
        .vendor_id = AMZ_VENDOR_ID,
    };
    try testing.expect(string.equals(try nvme.name(), "ephemeral0"));
}

test "nvme struct both device_name and virtual_name" {
    const nvme = Nvme{
        .model = Model.AmazonElasticBlockStore,
        .names = Names{
            .device_name = "sdf",
            .virtual_name = "ephemeral0",
        },
        .vendor_id = AMZ_VENDOR_ID,
    };
    try testing.expect(string.equals(try nvme.name(), "sdf"));
}

test "parseModel ebs space padded" {
    var mn: [40]u8 = undefined;
    @memset(&mn, ' ');
    @memcpy(mn[0..AMZ_EBS_MN.len], AMZ_EBS_MN);
    try testing.expectEqual(Model.AmazonElasticBlockStore, try parseModel(&mn));
}

test "parseModel ebs null padded" {
    var mn: [40]u8 = undefined;
    @memset(&mn, 0);
    @memcpy(mn[0..AMZ_EBS_MN.len], AMZ_EBS_MN);
    try testing.expectEqual(Model.AmazonElasticBlockStore, try parseModel(&mn));
}

test "parseModel ebs exact length" {
    // Model string that fills exactly 40 bytes (won't happen in
    // practice, but verifies no off-by-one).
    var mn: [40]u8 = undefined;
    @memset(&mn, 'x');
    @memcpy(mn[0..AMZ_EBS_MN.len], AMZ_EBS_MN);
    try testing.expectError(Error.UnknownModelNumber, parseModel(&mn));
}

test "parseModel instance store space padded" {
    var mn: [40]u8 = undefined;
    @memset(&mn, ' ');
    @memcpy(mn[0..AMZ_INST_STORE_MN.len], AMZ_INST_STORE_MN);
    try testing.expectEqual(Model.AmazonInstanceStore, try parseModel(&mn));
}

test "parseModel instance store null padded" {
    var mn: [40]u8 = undefined;
    @memset(&mn, 0);
    @memcpy(mn[0..AMZ_INST_STORE_MN.len], AMZ_INST_STORE_MN);
    try testing.expectEqual(Model.AmazonInstanceStore, try parseModel(&mn));
}

test "parseModel unknown" {
    var mn: [40]u8 = undefined;
    @memset(&mn, 0);
    @memcpy(mn[0..7], "Unknown");
    try testing.expectError(Error.UnknownModelNumber, parseModel(&mn));
}

test "parseModel all spaces" {
    var mn: [40]u8 = undefined;
    @memset(&mn, ' ');
    try testing.expectError(Error.UnknownModelNumber, parseModel(&mn));
}

test "parseModel all nulls" {
    var mn: [40]u8 = undefined;
    @memset(&mn, 0);
    try testing.expectError(Error.UnknownModelNumber, parseModel(&mn));
}
