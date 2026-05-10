//! Render Mustache template volumes to files. Templates may reference
//! variables resolved from env / env-from via `$(VAR)` expansion, and
//! iterate over sequences via Mustache sections.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const testing = std.testing;

const k8s_expand = @import("k8s_expand");
const mustache = @import("mustache");
const yaml = @import("yaml");

const fs = @import("fs.zig");
const Mount = @import("vmspec.zig").Mount;
const NameValue = @import("vmspec.zig").NameValue;
const TemplateVolumeSource = @import("vmspec.zig").TemplateVolumeSource;

pub const Error = error{
    InvalidVariableMapping,
    NonStringMappingKey,
};

pub fn renderToFile(
    allocator: Allocator,
    io: Io,
    tmpl: *const TemplateVolumeSource,
    env: []const NameValue,
) !void {
    const destination = tmpl.mount.destination;
    const mode = try parseMode(tmpl.mount.mode, 0o644);

    if (std.fs.path.dirname(destination)) |parent| {
        try fs.mkdirRecursive(io, parent, 0o755);
    }

    const mapping: ?yaml.Value.ObjectMap = if (tmpl.variables) |v| switch (v) {
        .object => |m| m,
        else => return Error.InvalidVariableMapping,
    } else null;

    if (mapping == null or mapping.?.count() == 0) {
        try fs.atomicWriteFile(io, destination, tmpl.content, mode);
        try applyOwnership(io, destination, tmpl.mount);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var env_map = std.StringHashMap([]const u8).init(arena_allocator);
    for (env) |nv| try env_map.put(nv.name, nv.value);
    const context = [_]*const std.StringHashMap([]const u8){&env_map};

    const json_value = try yamlToJson(arena_allocator, .{ .object = mapping.? }, &context);

    const parse_result = try mustache.parseText(
        arena_allocator,
        tmpl.content,
        .{},
        .{ .copy_strings = false },
    );
    const parsed_template = switch (parse_result) {
        .success => |t| t,
        .parse_error => |detail| return detail.parse_error,
    };
    const rendered = try mustache.allocRender(arena_allocator, parsed_template, json_value);

    try fs.atomicWriteFile(io, destination, rendered, mode);
    try applyOwnership(io, destination, tmpl.mount);
}

fn yamlToJson(
    allocator: Allocator,
    v: yaml.Value,
    context: k8s_expand.Context,
) !std.json.Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try k8s_expand.expand(allocator, s, context) },
        .array => |seq| blk: {
            var arr = std.json.Array.init(allocator);
            try arr.ensureTotalCapacity(seq.items.len);
            for (seq.items) |item| {
                arr.appendAssumeCapacity(try yamlToJson(allocator, item, context));
            }
            break :blk .{ .array = arr };
        },
        .object => |m| blk: {
            var obj: std.json.ObjectMap = .empty;
            try obj.ensureTotalCapacity(allocator, m.count());
            var it = m.iterator();
            while (it.next()) |entry| {
                const key = switch (entry.key_ptr.*) {
                    .string => |s| s,
                    else => return Error.NonStringMappingKey,
                };
                try obj.put(allocator, key, try yamlToJson(allocator, entry.value_ptr.*, context));
            }
            break :blk .{ .object = obj };
        },
    };
}

fn parseMode(s: ?[]const u8, default: posix.mode_t) !posix.mode_t {
    const str = s orelse return default;
    return std.fmt.parseInt(posix.mode_t, str, 8);
}

fn applyOwnership(io: Io, path: []const u8, mount: Mount) !void {
    if (mount.@"user-id" == null and mount.@"group-id" == null) return;
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.setOwner(io, mount.@"user-id", mount.@"group-id");
}

// ---- tests ----

fn buildSource(
    content: []const u8,
    variables: ?yaml.Value,
    destination: []const u8,
) TemplateVolumeSource {
    return .{
        .content = content,
        .variables = variables,
        .mount = .{ .destination = destination },
    };
}

fn makeMapping(
    allocator: Allocator,
    keys: []const yaml.Value,
    vals: []const yaml.Value,
) !yaml.Value {
    std.debug.assert(keys.len == vals.len);
    var m: yaml.Value.ObjectMap = .empty;
    try m.ensureTotalCapacity(allocator, keys.len);
    for (keys, vals) |k, v| try m.put(allocator, k, v);
    return .{ .object = m };
}

fn makeArray(allocator: Allocator, items: []const yaml.Value) !yaml.Value {
    var arr: yaml.Value.Array = .empty;
    try arr.appendSlice(allocator, items);
    return .{ .array = arr };
}

fn readAllAlloc(allocator: Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]u8 {
    return try dir.readFileAlloc(io, path, allocator, .limited(1 << 20));
}

fn tmpDestPath(
    allocator: Allocator,
    tmp_dir: std.testing.TmpDir,
    rel: []const u8,
) ![]u8 {
    const dir_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(dir_path);
    return try std.fs.path.join(allocator, &.{ dir_path, rel });
}

test "renderToFile writes literal content when variables is null" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const src = buildSource("hello world", null, dest);
    try renderToFile(testing.allocator, testing.io, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, testing.io, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("hello world", actual);
}

test "renderToFile writes literal content when variables is empty mapping" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const variables = try makeMapping(arena.allocator(), &.{}, &.{});

    const src = buildSource("hello {{name}}", variables, dest);
    try renderToFile(testing.allocator, testing.io, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, testing.io, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("hello {{name}}", actual);
}

test "renderToFile errors when variables is not a mapping" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const variables: yaml.Value = .{ .string = "not a mapping" };

    const src = buildSource("hello", variables, dest);
    try testing.expectError(
        Error.InvalidVariableMapping,
        renderToFile(testing.allocator, testing.io, &src, &.{}),
    );
}

test "renderToFile substitutes scalar variable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const keys = [_]yaml.Value{.{ .string = "name" }};
    const vals = [_]yaml.Value{.{ .string = "world" }};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const variables = try makeMapping(arena.allocator(), &keys, &vals);

    const src = buildSource("hello {{name}}", variables, dest);
    try renderToFile(testing.allocator, testing.io, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, testing.io, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("hello world", actual);
}

test "renderToFile iterates mustache section over sequence of maps" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const item1_keys = [_]yaml.Value{.{ .string = "name" }};
    const item1_vals = [_]yaml.Value{.{ .string = "Milk" }};
    const item2_keys = [_]yaml.Value{.{ .string = "name" }};
    const item2_vals = [_]yaml.Value{.{ .string = "Eggs" }};
    const items = [_]yaml.Value{
        try makeMapping(aa, &item1_keys, &item1_vals),
        try makeMapping(aa, &item2_keys, &item2_vals),
    };

    const top_keys = [_]yaml.Value{.{ .string = "items" }};
    const top_vals = [_]yaml.Value{try makeArray(aa, &items)};
    const variables = try makeMapping(aa, &top_keys, &top_vals);

    const src = buildSource("{{#items}}- {{name}}\n{{/items}}", variables, dest);
    try renderToFile(testing.allocator, testing.io, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, testing.io, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("- Milk\n- Eggs\n", actual);
}

test "renderToFile expands dollar-paren vars inside variables" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = [_]yaml.Value{.{ .string = "greeting" }};
    const vals = [_]yaml.Value{.{ .string = "Hello, $(NAME)!" }};
    const variables = try makeMapping(arena.allocator(), &keys, &vals);

    const env = [_]NameValue{.{ .name = "NAME", .value = "Claude" }};
    const src = buildSource("{{greeting}}", variables, dest);
    try renderToFile(testing.allocator, testing.io, &src, &env);

    const actual = try readAllAlloc(testing.allocator, testing.io, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("Hello, Claude!", actual);
}

test "renderToFile leaves unresolved dollar-paren unchanged" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = [_]yaml.Value{.{ .string = "val" }};
    const vals = [_]yaml.Value{.{ .string = "$(MISSING)" }};
    const variables = try makeMapping(arena.allocator(), &keys, &vals);

    const src = buildSource("{{val}}", variables, dest);
    try renderToFile(testing.allocator, testing.io, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, testing.io, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("$(MISSING)", actual);
}

test "renderToFile errors on non-string mapping key" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = [_]yaml.Value{.{ .integer = 42 }};
    const vals = [_]yaml.Value{.{ .string = "x" }};
    const variables = try makeMapping(arena.allocator(), &keys, &vals);

    const src = buildSource("{{val}}", variables, dest);
    try testing.expectError(
        Error.NonStringMappingKey,
        renderToFile(testing.allocator, testing.io, &src, &.{}),
    );
}

test "renderToFile expands dollar-paren inside nested sequence" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const item1_keys = [_]yaml.Value{.{ .string = "url" }};
    const item1_vals = [_]yaml.Value{.{ .string = "$(URL)" }};
    const items = [_]yaml.Value{try makeMapping(aa, &item1_keys, &item1_vals)};
    const top_keys = [_]yaml.Value{.{ .string = "items" }};
    const top_vals = [_]yaml.Value{try makeArray(aa, &items)};
    const variables = try makeMapping(aa, &top_keys, &top_vals);

    const env = [_]NameValue{.{ .name = "URL", .value = "https://example.com" }};
    const src = buildSource("{{#items}}{{url}}{{/items}}", variables, dest);
    try renderToFile(testing.allocator, testing.io, &src, &env);

    const actual = try readAllAlloc(testing.allocator, testing.io, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("https://example.com", actual);
}
