//! BDD spec for src/tools/file_edit.zig — exact-string-replace edit.
//! old_string must match exactly once in the file; this is one of the
//! plan's explicitly-called-out scenarios (zero/multiple/exactly-one).
const std = @import("std");
const opennull = @import("opennull");
const sandbox = opennull.security;
const tool = opennull.tools.tool;

fn workspaceRootOf(dir: std.Io.Dir, buf: []u8) []const u8 {
    const len = dir.realPath(std.testing.io, buf) catch @panic("realPath failed in test setup");
    return buf[0..len];
}

fn editArgs(allocator: std.mem.Allocator, path: []const u8, old: []const u8, new: []const u8) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "old_string", .{ .string = old });
    try obj.put(allocator, "new_string", .{ .string = new });
    return obj;
}

// Scenario: Given old_string appears exactly once in the file, when edited,
// then only that occurrence is replaced and the rest of the file survives.
test "replaces the single occurrence of old_string" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.zig", .data = "const x = 1;\nconst y = 2;\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try editArgs(std.testing.allocator, "f.zig", "const x = 1;", "const x = 100;");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_edit = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "f.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("const x = 100;\nconst y = 2;\n", contents);
}

// Scenario: Given old_string does not appear anywhere in the file, when
// edited, then it fails with a clear error and the file is left untouched.
test "errors when old_string is not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.zig", .data = "const x = 1;\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try editArgs(std.testing.allocator, "f.zig", "does not exist", "new");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_edit = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "f.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("const x = 1;\n", contents);
}

// Scenario: Given old_string appears more than once in the file, when
// edited, then it fails as ambiguous rather than guessing which occurrence
// was meant, and the file is left untouched.
test "errors when old_string is ambiguous (multiple matches)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.zig", .data = "dup\ndup\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try editArgs(std.testing.allocator, "f.zig", "dup", "single");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_edit = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "f.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("dup\ndup\n", contents);
}

// Scenario: Given an empty new_string, when edited, then the matched text
// is deleted rather than replaced with something else.
test "empty new_string deletes the matched text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.zig", .data = "keep DELETE_ME keep\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try editArgs(std.testing.allocator, "f.zig", "DELETE_ME ", "");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_edit = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "f.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("keep keep\n", contents);
}

// Scenario: Given an empty old_string, when edited, then it is rejected as
// invalid input rather than matching "everywhere" ambiguously.
test "rejects an empty old_string" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.zig", .data = "content\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try editArgs(std.testing.allocator, "f.zig", "", "new");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_edit = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
}

// Scenario: Given a path that escapes the workspace, when file_edit is
// executed, then it fails and never touches the filesystem outside it.
test "rejects editing a path outside the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try editArgs(std.testing.allocator, "../escape.zig", "a", "b");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_edit = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
}
