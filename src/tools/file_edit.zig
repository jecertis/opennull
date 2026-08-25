//! Exact-string-replace edit: `old_string` must match exactly once in the
//! file (zero matches errors as not-found, multiple matches errors as
//! ambiguous), an empty `new_string` deletes the matched text. See
//! test/file_edit_test.zig for scenarios.
const std = @import("std");
const sandbox = @import("../security/sandbox.zig");
const tool = @import("tool.zig");

pub const FileEditTool = struct {
    pub fn spec(self: FileEditTool, allocator: std.mem.Allocator) !tool.ToolSpec {
        _ = self;
        const schema = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file, relative to the workspace root"},"old_string":{"type":"string","description":"The exact text to find and replace; must appear exactly once in the file"},"new_string":{"type":"string","description":"The replacement text; empty string deletes the matched text"}},"required":["path","old_string","new_string"]}
        , .{});
        return .{
            .name = "file_edit",
            .description = "Edit a file by replacing an exact, single occurrence of old_string with new_string",
            .parameters_schema = schema,
        };
    }

    pub fn execute(
        self: FileEditTool,
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
        const old_string = switch (obj.get("old_string") orelse
            return .{ .success = false, .output = "", .err = "missing required 'old_string' argument" }) {
            .string => |s| s,
            else => return .{ .success = false, .output = "", .err = "'old_string' must be a string" },
        };
        const new_string = switch (obj.get("new_string") orelse
            return .{ .success = false, .output = "", .err = "missing required 'new_string' argument" }) {
            .string => |s| s,
            else => return .{ .success = false, .output = "", .err = "'new_string' must be a string" },
        };

        if (old_string.len == 0) {
            return .{ .success = false, .output = "", .err = "old_string must not be empty" };
        }

        const allowed = try policy.isAllowed(allocator, path);
        if (!allowed) {
            return .{ .success = false, .output = "", .err = "path is outside the allowed workspace" };
        }

        const resolved = try policy.resolvePath(allocator, path);
        defer allocator.free(resolved);

        const contents = std.Io.Dir.cwd().readFileAlloc(io, resolved, allocator, .unlimited) catch |err| {
            return .{ .success = false, .output = "", .err = @errorName(err) };
        };
        defer allocator.free(contents);

        const occurrences = std.mem.count(u8, contents, old_string);
        if (occurrences == 0) {
            return .{ .success = false, .output = "", .err = "old_string not found in file" };
        }
        if (occurrences > 1) {
            return .{ .success = false, .output = "", .err = "old_string matches more than once; must match exactly once" };
        }

        const match_at = std.mem.indexOf(u8, contents, old_string).?;
        var new_contents: std.ArrayListUnmanaged(u8) = .empty;
        defer new_contents.deinit(allocator);
        try new_contents.appendSlice(allocator, contents[0..match_at]);
        try new_contents.appendSlice(allocator, new_string);
        try new_contents.appendSlice(allocator, contents[match_at + old_string.len ..]);

        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = new_contents.items }) catch |err| {
            return .{ .success = false, .output = "", .err = @errorName(err) };
        };

        return .{ .success = true, .output = "" };
    }
};
