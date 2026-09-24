//! BDD spec for src/tools/grep.zig, against a real temp workspace.
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
    return (tool.Tool{ .grep = .{} }).execute(std.testing.allocator, io, policy, args.value);
}

const Workspace = struct {
    tmp: std.testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    policy: sandbox.SecurityPolicy = undefined,

    fn init(self: *Workspace) !void {
        self.tmp = std.testing.tmpDir(.{});
        const d = self.tmp.dir;
        try d.createDirPath(io, "src/util");
        try d.createDirPath(io, ".git");
        try d.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const x = 1;\npub fn main() void {}\n" });
        try d.writeFile(io, .{ .sub_path = "src/util/helper.zig", .data = "pub fn Helper() void {}\n// helper notes\n" });
        try d.writeFile(io, .{ .sub_path = ".git/config", .data = "pub fn main in git metadata\n" });
        try d.writeFile(io, .{ .sub_path = "blob.bin", .data = "pub fn main\x00binary" });
        try d.symLink(io, "src/main.zig", "alias.zig", .{});
        self.policy = .{ .workspace_root = rootOf(d, &self.buf) };
    }
};

// Scenario: Given a workspace, when searching for "pub fn main", then only
// the real source match is returned, as path:line — .git, binary files and
// symlinks are not searched.
test "finds matches and skips .git, binaries and symlinks" {
    var ws: Workspace = .{ .tmp = undefined };
    try ws.init();
    defer ws.tmp.cleanup();
    const r = try run(&ws.policy, "{\"pattern\":\"pub fn main\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.success);
    try std.testing.expectEqualStrings("src/main.zig:2: pub fn main() void {}\n", r.output);
}

// Scenario: Given ignore_case and a subdirectory path, when searching, then
// matches are case-insensitive and paths keep the requested prefix.
test "ignore_case within a subdirectory" {
    var ws: Workspace = .{ .tmp = undefined };
    try ws.init();
    defer ws.tmp.cleanup();
    const r = try run(&ws.policy, "{\"pattern\":\"HELPER\",\"path\":\"src/util\",\"ignore_case\":true}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqualStrings("src/util/helper.zig:1: pub fn Helper() void {}\nsrc/util/helper.zig:2: // helper notes\n", r.output);
}

// Scenario: Given a single file path, when searching, then only that file
// is searched.
test "searches a single file" {
    var ws: Workspace = .{ .tmp = undefined };
    try ws.init();
    defer ws.tmp.cleanup();
    const r = try run(&ws.policy, "{\"pattern\":\"const\",\"path\":\"src/main.zig\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqualStrings("src/main.zig:1: const x = 1;\n", r.output);
}

// Scenario: Given no match, a path outside, or a missing pattern, when
// searching, then the result says so plainly.
test "no matches, outside paths and bad arguments" {
    var ws: Workspace = .{ .tmp = undefined };
    try ws.init();
    defer ws.tmp.cleanup();
    const none = try run(&ws.policy, "{\"pattern\":\"zzz-not-here\"}");
    defer std.testing.allocator.free(none.output);
    try std.testing.expectEqualStrings("no matches\n", none.output);
    const outside = try run(&ws.policy, "{\"pattern\":\"x\",\"path\":\"../\"}");
    try std.testing.expect(!outside.success);
    const missing = try run(&ws.policy, "{}");
    try std.testing.expectEqualStrings("missing required 'pattern' argument", missing.err.?);
}

// Scenario: Given more than 200 matching lines, when searching, then output
// stops at 200 and says so.
test "caps output at 200 matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const many = "hit\n" ** 250;
    try tmp.dir.writeFile(io, .{ .sub_path = "many.txt", .data = many });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = rootOf(tmp.dir, &buf) };
    const r = try run(&policy, "{\"pattern\":\"hit\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqual(@as(usize, 201), std.mem.count(u8, r.output, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, r.output, "... stopped after 200 matches\n"));
}
