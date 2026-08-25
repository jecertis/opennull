//! Compile-time list of enabled tools, plus the specs/dispatch built from
//! it. See test/registry_test.zig for scenarios.
const std = @import("std");
const tool = @import("tool.zig");

pub const enabled_tools = [_]tool.Tool{
    .{ .file_read = .{} },
    .{ .file_write = .{} },
    .{ .file_edit = .{} },
};

/// Builds one ToolSpec per enabled tool, for the provider's function-
/// calling payload. Allocates from `allocator` — callers typically pass an
/// arena that lives for the request/session.
pub fn buildSpecs(allocator: std.mem.Allocator) ![]tool.ToolSpec {
    const out = try allocator.alloc(tool.ToolSpec, enabled_tools.len);
    for (enabled_tools, 0..) |t, i| out[i] = try t.spec(allocator);
    return out;
}

/// Finds an enabled tool by its dispatch name (see Tool.name()).
pub fn find(name: []const u8) ?tool.Tool {
    for (enabled_tools) |t| {
        if (std.mem.eql(u8, t.name(), name)) return t;
    }
    return null;
}
