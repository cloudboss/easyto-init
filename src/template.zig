//! Render Mustache template volumes to files. Templates may reference
//! variables resolved from env / env-from via `$(VAR)` expansion, and
//! iterate over sequences via Mustache sections.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const yaml = @import("yaml");

const vmspec = @import("vmspec.zig");
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
    _ = allocator;
    _ = tmpl;
    _ = env;
    return error.NotImplemented;
}

// The tests below define the contract for `renderToFile`. They currently
// fail against the stub; Phase 3 makes them pass.

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
