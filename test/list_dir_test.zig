//! BDD spec for src/tools/list_dir.zig, against a real temp workspace.
const std = @import("std");
const opennull = @import("opennull");
const sandbox = opennull.security;
const tool = opennull.tools.tool;
const io = std.testing.io;

fn rootOf(dir: std.Io.Dir, buf: []u8) []const u8 {
    const n = dir.realPath(io, buf) catch @panic("realPath failed in test setup");
    return buf[0..n];
}

fn run(policy: *const sandbox.SecurityPolicy, json: []const u8) !tool.ToolResult {
    const args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer args.deinit();
    return (tool.Tool{ .list_dir = .{} }).execute(std.testing.allocator, io, policy, args.value);
}

// Scenario: Given files, a subdirectory and a symlink, when the root is
// listed with no path, then entries come back sorted with '/' and '@'
// markers.
test "lists the workspace root sorted with kind markers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.symLink(io, "a.txt", "link", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = rootOf(tmp.dir, &buf) };

    const r = try run(&policy, "{}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.success);
    try std.testing.expectEqualStrings("a.txt\nb.txt\nlink@\nsrc/\n", r.output);
}

// Scenario: Given a path outside the workspace, or a symlinked directory
// leading outside, when listed, then it is refused.
test "refuses directories outside the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_root = rootOf(outside.dir, &out_buf);
    try tmp.dir.symLink(io, out_root, "out", .{ .is_directory = true });
    const policy = sandbox.SecurityPolicy{ .workspace_root = rootOf(tmp.dir, &buf) };

    const up = try run(&policy, "{\"path\":\"..\"}");
    try std.testing.expect(!up.success);
    const via_link = try run(&policy, "{\"path\":\"out\"}");
    try std.testing.expect(!via_link.success);
    try std.testing.expectEqualStrings("path is outside the allowed workspace", via_link.err.?);
}
