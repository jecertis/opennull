//! BDD spec for src/tools/file_read.zig. Uses a real temp directory
//! (std.testing.tmpDir) and std.testing.io, since file reading is genuinely
//! filesystem I/O — the sandbox check itself stays covered separately and
//! purely in test/sandbox_test.zig.
const std = @import("std");
const opennull = @import("opennull");
const sandbox = opennull.security;
const tool = opennull.tools.tool;

fn workspaceRootOf(dir: std.Io.Dir, buf: []u8) []const u8 {
    const len = dir.realPath(std.testing.io, buf) catch @panic("realPath failed in test setup");
    return buf[0..len];
}

/// Builds `{"path": path}` as an owned ObjectMap the caller must `.deinit()`.
fn pathArgs(allocator: std.mem.Allocator, path: []const u8) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "path", .{ .string = path });
    return obj;
}

// Scenario: Given a file that exists inside the workspace, when file_read
// is executed with its relative path, then it succeeds and returns the
// file's exact contents.
test "reads a file within the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "hello world" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try pathArgs(std.testing.allocator, "hello.txt");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_read = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("hello world", result.output);
}

// Scenario: Given a path that escapes the workspace, when file_read is
// executed, then it fails with a clear error and never touches the
// filesystem outside the workspace.
test "rejects a path outside the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try pathArgs(std.testing.allocator, "../outside.txt");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_read = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
}

// Scenario: Given a path that is inside the workspace but doesn't exist,
// when file_read is executed, then it returns a failure result rather than
// crashing or returning garbage.
test "returns a failure result for a missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try pathArgs(std.testing.allocator, "missing.txt");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_read = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
}

// Scenario: Given arguments missing the required 'path' field, when
// file_read is executed, then it fails with a clear error instead of
// panicking on a null field access.
test "rejects arguments missing the path field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    const t = tool.Tool{ .file_read = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = .empty });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
}

// Scenario: Given the file_read tool, when its spec is built, then it
// declares the "path" parameter as required.
test "spec declares path as a required string parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const t = tool.Tool{ .file_read = .{} };
    const spec = try t.spec(arena.allocator());

    try std.testing.expectEqualStrings("file_read", spec.name);
    const required = spec.parameters_schema.object.get("required").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), required.len);
    try std.testing.expectEqualStrings("path", required[0].string);
}
