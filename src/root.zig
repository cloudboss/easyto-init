const std = @import("std");

const container = @import("container.zig");
const fs = @import("fs.zig");
const init = @import("init.zig");
const login = @import("login.zig");
const nvme = @import("nvme-amz.zig");
const string = @import("string.zig");
const system = @import("system.zig");
const vmspec = @import("vmspec.zig");

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(container);
    testing.refAllDecls(fs);
    testing.refAllDecls(init);
    testing.refAllDecls(login);
    testing.refAllDecls(nvme);
    testing.refAllDecls(string);
    testing.refAllDecls(system);
    testing.refAllDecls(vmspec);
}
