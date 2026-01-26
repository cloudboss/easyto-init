const std = @import("std");

const backoff = @import("backoff.zig");
const container = @import("container.zig");
const fs = @import("fs.zig");
const init = @import("init.zig");
const login = @import("login.zig");
const network = @import("network.zig");
const nvme = @import("nvme-amz.zig");
const string = @import("string.zig");
const system = @import("system.zig");
const vmspec = @import("vmspec.zig");
const yaml = @import("yaml.zig");

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(backoff);
    testing.refAllDecls(container);
    testing.refAllDecls(fs);
    testing.refAllDecls(init);
    testing.refAllDecls(login);
    testing.refAllDecls(network);
    testing.refAllDecls(nvme);
    testing.refAllDecls(string);
    testing.refAllDecls(system);
    testing.refAllDecls(vmspec);
    testing.refAllDecls(yaml);
}
