//! BDD spec for src/tools/file_write.zig. Real filesystem I/O via
//! std.testing.tmpDir + std.testing.io, same pattern as file_read_test.zig.
const std = @import("std");
const opennull = @import("opennull");
const sandbox = opennull.security;
const tool = opennull.tools.tool;

fn workspaceRootOf(dir: std.Io.Dir, buf: []u8) []const u8 {
    const len = dir.realPath(std.testing.io, buf) catch @panic("realPath failed in test setup");
    return buf[0..len];
}

fn writeArgs(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "content", .{ .string = content });
    return obj;
}

// Scenario: Given a path inside the workspace, when file_write is
// executed, then the file is created with exactly the given content.
test "writes a new file within the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try writeArgs(std.testing.allocator, "out.txt", "written content");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_write = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "out.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("written content", contents);
}

// Scenario: Given a path that escapes the workspace, when file_write is
// executed, then it fails and never touches the filesystem outside it.
test "rejects writing outside the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try writeArgs(std.testing.allocator, "../escape.txt", "malicious");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_write = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
}

// Scenario: Given a path to an existing file within the workspace, when
// file_write is executed, then the existing content is fully replaced.
test "overwrites an existing file within the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "existing.txt", .data = "old content that is longer" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var args = try writeArgs(std.testing.allocator, "existing.txt", "new");
    defer args.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_write = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = args });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "existing.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("new", contents);
}

// Scenario: Given arguments missing the required 'content' field, when
// file_write is executed, then it fails with a clear error rather than
// crashing or writing an empty/garbage file.
test "rejects arguments missing the content field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(std.testing.allocator, "path", .{ .string = "out.txt" });
    defer obj.deinit(std.testing.allocator);

    const t = tool.Tool{ .file_write = .{} };
    const result = try t.execute(std.testing.allocator, std.testing.io, &policy, .{ .object = obj });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
}
