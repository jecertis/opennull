//! Lists one directory inside the sandboxed workspace, so the model can find
//! files instead of guessing paths. Read-only. See test/list_dir_test.zig.
const std = @import("std");
const sandbox = @import("../security/sandbox.zig");
const tool = @import("tool.zig");

const max_entries = 1000;

pub const ListDirTool = struct {
    pub fn spec(self: ListDirTool, allocator: std.mem.Allocator) !tool.ToolSpec {
        _ = self;
        const schema = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to list, relative to the workspace root; defaults to the root"}}}
        , .{});
        return .{
            .name = "list_dir",
            .description = "List a directory's entries (one level), sorted; directories end in '/', symlinks in '@'",
            .parameters_schema = schema,
        };
    }

    pub fn execute(
        self: ListDirTool,
        allocator: std.mem.Allocator,
        io: std.Io,
        policy: *const sandbox.SecurityPolicy,
        args: std.json.Value,
    ) !tool.ToolResult {
        _ = self;
        const path = switch (optionalString(args, "path")) {
            .ok => |p| p orelse ".",
            .bad => |msg| return .{ .success = false, .output = "", .err = msg },
        };
        if (!try policy.isAllowed(allocator, path)) {
            return .{ .success = false, .output = "", .err = "path is outside the allowed workspace" };
        }
        const resolved = (try policy.resolveReal(allocator, io, path)) orelse
            return .{ .success = false, .output = "", .err = "path is outside the allowed workspace" };
        defer allocator.free(resolved);

        var dir = std.Io.Dir.cwd().openDir(io, resolved, .{ .iterate = true }) catch |err| {
            return .{ .success = false, .output = "", .err = @errorName(err) };
        };
        defer dir.close(io);

        var names: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        var total: usize = 0;
        var it = dir.iterate();
        while (it.next(io) catch |err| return .{ .success = false, .output = "", .err = @errorName(err) }) |entry| {
            total += 1;
            if (names.items.len == max_entries) continue;
            const suffix: []const u8 = switch (entry.kind) {
                .directory => "/",
                .sym_link => "@",
                else => "",
            };
            try names.append(allocator, try std.mem.concat(allocator, u8, &.{ entry.name, suffix }));
        }
        std.mem.sort([]u8, names.items, {}, lessThan);

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        for (names.items) |n| try out.writer.print("{s}\n", .{n});
        if (total > names.items.len) try out.writer.print("... {d} more entries not shown\n", .{total - names.items.len});
        if (total == 0) try out.writer.writeAll("(empty directory)\n");
        return .{ .success = true, .output = try out.toOwnedSlice() };
    }
};

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub const OptionalString = union(enum) { ok: ?[]const u8, bad: []const u8 };

/// Reads an optional string argument; the error message names the key.
pub fn optionalString(args: std.json.Value, comptime key: []const u8) OptionalString {
    const obj = switch (args) {
        .object => |o| o,
        else => return .{ .bad = "arguments must be a JSON object" },
    };
    const v = obj.get(key) orelse return .{ .ok = null };
    return switch (v) {
        .string => |s| .{ .ok = s },
        .null => .{ .ok = null },
        else => .{ .bad = "'" ++ key ++ "' must be a string" },
    };
}
