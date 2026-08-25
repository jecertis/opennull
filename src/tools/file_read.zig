//! Reads the full contents of a file within the sandboxed workspace. See
//! test/file_read_test.zig for scenarios.
const std = @import("std");
const sandbox = @import("../security/sandbox.zig");
const tool = @import("tool.zig");

pub const FileReadTool = struct {
    pub fn spec(self: FileReadTool, allocator: std.mem.Allocator) !tool.ToolSpec {
        _ = self;
        const schema = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file, relative to the workspace root (or absolute within an allowed location)"}},"required":["path"]}
        , .{});
        return .{
            .name = "file_read",
            .description = "Read the full contents of a file within the workspace",
            .parameters_schema = schema,
        };
    }

    pub fn execute(
        self: FileReadTool,
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

        const allowed = try policy.isAllowed(allocator, path);
        if (!allowed) {
            return .{ .success = false, .output = "", .err = "path is outside the allowed workspace" };
        }

        const resolved = try policy.resolvePath(allocator, path);
        defer allocator.free(resolved);

        const contents = std.Io.Dir.cwd().readFileAlloc(io, resolved, allocator, .unlimited) catch |err| {
            return .{ .success = false, .output = "", .err = @errorName(err) };
        };

        return .{ .success = true, .output = contents };
    }
};
