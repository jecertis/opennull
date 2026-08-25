//! Writes (creating or overwriting) a file within the sandboxed workspace.
//! See test/file_write_test.zig for scenarios.
const std = @import("std");
const sandbox = @import("../security/sandbox.zig");
const tool = @import("tool.zig");

pub const FileWriteTool = struct {
    pub fn spec(self: FileWriteTool, allocator: std.mem.Allocator) !tool.ToolSpec {
        _ = self;
        const schema = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file, relative to the workspace root"},"content":{"type":"string","description":"Full contents to write"}},"required":["path","content"]}
        , .{});
        return .{
            .name = "file_write",
            .description = "Create or overwrite a file within the workspace with the given content",
            .parameters_schema = schema,
        };
    }

    pub fn execute(
        self: FileWriteTool,
        allocator: std.mem.Allocator,
        io: std.Io,
        policy: *const sandbox.SecurityPolicy,
        args: std.json.Value,
    ) !tool.ToolResult {
        _ = self;

        const obj = switch (args) {
            .object => |o| o,
            else => return .{ .success = false, .output = "", .err = "arguments must be a JSON object" },
        };
        const path = switch (obj.get("path") orelse
            return .{ .success = false, .output = "", .err = "missing required 'path' argument" }) {
            .string => |s| s,
            else => return .{ .success = false, .output = "", .err = "'path' must be a string" },
        };
        const content = switch (obj.get("content") orelse
            return .{ .success = false, .output = "", .err = "missing required 'content' argument" }) {
            .string => |s| s,
            else => return .{ .success = false, .output = "", .err = "'content' must be a string" },
        };

        const allowed = try policy.isAllowed(allocator, path);
        if (!allowed) {
            return .{ .success = false, .output = "", .err = "path is outside the allowed workspace" };
        }

        const resolved = try policy.resolvePath(allocator, path);
        defer allocator.free(resolved);

        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = content }) catch |err| {
            return .{ .success = false, .output = "", .err = @errorName(err) };
        };

        return .{ .success = true, .output = "" };
    }
};
