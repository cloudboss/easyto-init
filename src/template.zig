//! Render Mustache template volumes to files. Templates may reference
//! variables resolved from env / env-from via `$(VAR)` expansion, and
//! iterate over sequences via Mustache sections.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const k8s_expand = @import("k8s_expand");
const mustache = @import("mustache");
const yaml = @import("yaml");

const fs = @import("fs.zig");
const vmspec = @import("vmspec.zig");
const Mount = vmspec.Mount;
const NameValue = vmspec.NameValue;
const TemplateVolumeSource = vmspec.TemplateVolumeSource;

pub const Error = error{
    NonStringMappingKey,
};

pub fn renderToFile(
    allocator: Allocator,
    tmpl: *const TemplateVolumeSource,
    env: []const NameValue,
) !void {
    const destination = tmpl.mount.destination;
    const mode = try parseMode(tmpl.mount.mode, 0o644);

    if (std.fs.path.dirname(destination)) |parent| {
        try fs.mkdir_p(parent, 0o755);
    }

    if (tmpl.variables == null) {
        try fs.atomicWriteFile(destination, tmpl.content, mode);
        try applyOwnership(destination, tmpl.mount);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var env_map = std.StringHashMap([]const u8).init(arena_allocator);
    for (env) |nv| try env_map.put(nv.name, nv.value);
    const context = [_]*const std.StringHashMap([]const u8){&env_map};

    const json_value = try yamlToJson(arena_allocator, tmpl.variables.?, &context);

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

    try fs.atomicWriteFile(destination, rendered, mode);
    try applyOwnership(destination, tmpl.mount);
}

fn yamlToJson(
    allocator: Allocator,
    v: yaml.Value,
    context: k8s_expand.Context,
) !std.json.Value {
    return switch (v) {
        .null => .null,
        .boolean => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try k8s_expand.expand(allocator, s, context) },
        .sequence => |seq| blk: {
            var arr = std.json.Array.init(allocator);
            try arr.ensureTotalCapacity(seq.len);
            for (seq) |item| {
                arr.appendAssumeCapacity(try yamlToJson(allocator, item, context));
            }
            break :blk .{ .array = arr };
        },
        .mapping => |m| blk: {
            var obj = std.json.ObjectMap.init(allocator);
            try obj.ensureTotalCapacity(m.keys.len);
            for (m.keys, m.values) |k, vv| {
                const key = switch (k) {
                    .string => |s| s,
                    else => return Error.NonStringMappingKey,
                };
                try obj.put(key, try yamlToJson(allocator, vv, context));
            }
            break :blk .{ .object = obj };
        },
    };
}

fn parseMode(s: ?[]const u8, default: std.fs.File.Mode) !std.fs.File.Mode {
    const str = s orelse return default;
    return std.fmt.parseInt(std.fs.File.Mode, str, 8);
}

fn applyOwnership(path: []const u8, mount: Mount) !void {
    if (mount.@"user-id" == null and mount.@"group-id" == null) return;
    try fs.chownPath(path, mount.@"user-id", mount.@"group-id");
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

fn readAllAlloc(allocator: Allocator, dir: std.fs.Dir, path: []const u8) ![]u8 {
    const file = try dir.openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1 << 20);
}

fn tmpDestPath(
    allocator: Allocator,
    tmp_dir: std.testing.TmpDir,
    rel: []const u8,
) ![]u8 {
    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    return try std.fs.path.join(allocator, &.{ dir_path, rel });
}

test "renderToFile writes literal content when variables is null" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const src = buildSource("hello world", null, dest);
    try renderToFile(testing.allocator, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("hello world", actual);
}

test "renderToFile substitutes scalar variable" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const keys = [_]yaml.Value{.{ .string = "name" }};
    const vals = [_]yaml.Value{.{ .string = "world" }};
    const variables: yaml.Value = .{
        .mapping = .{ .keys = &keys, .values = &vals },
    };

    const src = buildSource("hello {{name}}", variables, dest);
    try renderToFile(testing.allocator, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("hello world", actual);
}

test "renderToFile iterates mustache section over sequence of maps" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const item1_keys = [_]yaml.Value{.{ .string = "name" }};
    const item1_vals = [_]yaml.Value{.{ .string = "Milk" }};
    const item2_keys = [_]yaml.Value{.{ .string = "name" }};
    const item2_vals = [_]yaml.Value{.{ .string = "Eggs" }};
    const items = [_]yaml.Value{
        .{ .mapping = .{ .keys = &item1_keys, .values = &item1_vals } },
        .{ .mapping = .{ .keys = &item2_keys, .values = &item2_vals } },
    };

    const top_keys = [_]yaml.Value{.{ .string = "items" }};
    const top_vals = [_]yaml.Value{.{ .sequence = &items }};
    const variables: yaml.Value = .{
        .mapping = .{ .keys = &top_keys, .values = &top_vals },
    };

    const src = buildSource("{{#items}}- {{name}}\n{{/items}}", variables, dest);
    try renderToFile(testing.allocator, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("- Milk\n- Eggs\n", actual);
}

test "renderToFile expands dollar-paren vars inside variables" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const keys = [_]yaml.Value{.{ .string = "greeting" }};
    const vals = [_]yaml.Value{.{ .string = "Hello, $(NAME)!" }};
    const variables: yaml.Value = .{
        .mapping = .{ .keys = &keys, .values = &vals },
    };

    const env = [_]NameValue{.{ .name = "NAME", .value = "Claude" }};
    const src = buildSource("{{greeting}}", variables, dest);
    try renderToFile(testing.allocator, &src, &env);

    const actual = try readAllAlloc(testing.allocator, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("Hello, Claude!", actual);
}

test "renderToFile leaves unresolved dollar-paren unchanged" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const keys = [_]yaml.Value{.{ .string = "val" }};
    const vals = [_]yaml.Value{.{ .string = "$(MISSING)" }};
    const variables: yaml.Value = .{
        .mapping = .{ .keys = &keys, .values = &vals },
    };

    const src = buildSource("{{val}}", variables, dest);
    try renderToFile(testing.allocator, &src, &.{});

    const actual = try readAllAlloc(testing.allocator, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("$(MISSING)", actual);
}

test "renderToFile errors on non-string mapping key" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const keys = [_]yaml.Value{.{ .integer = 42 }};
    const vals = [_]yaml.Value{.{ .string = "x" }};
    const variables: yaml.Value = .{
        .mapping = .{ .keys = &keys, .values = &vals },
    };

    const src = buildSource("{{val}}", variables, dest);
    try testing.expectError(
        Error.NonStringMappingKey,
        renderToFile(testing.allocator, &src, &.{}),
    );
}

test "renderToFile expands dollar-paren inside nested sequence" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest = try tmpDestPath(testing.allocator, tmp_dir, "out.txt");
    defer testing.allocator.free(dest);

    const item1_keys = [_]yaml.Value{.{ .string = "url" }};
    const item1_vals = [_]yaml.Value{.{ .string = "$(URL)" }};
    const items = [_]yaml.Value{
        .{ .mapping = .{ .keys = &item1_keys, .values = &item1_vals } },
    };
    const top_keys = [_]yaml.Value{.{ .string = "items" }};
    const top_vals = [_]yaml.Value{.{ .sequence = &items }};
    const variables: yaml.Value = .{
        .mapping = .{ .keys = &top_keys, .values = &top_vals },
    };

    const env = [_]NameValue{.{ .name = "URL", .value = "https://example.com" }};
    const src = buildSource("{{#items}}{{url}}{{/items}}", variables, dest);
    try renderToFile(testing.allocator, &src, &env);

    const actual = try readAllAlloc(testing.allocator, tmp_dir.dir, "out.txt");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("https://example.com", actual);
}
