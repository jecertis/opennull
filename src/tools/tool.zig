//! Tool interface: a closed-set tagged union (not a vtable) — the tool set
//! is fixed at compile time, so this gives exhaustiveness checking, no
//! indirect calls, and a smaller binary than dynamic dispatch. Every
//! concrete tool implements `spec(allocator) -> ToolSpec` and
//! `execute(allocator, io, policy, args) -> ToolResult`.
const std = @import("std");
const sandbox = @import("../security/sandbox.zig");
const file_read = @import("file_read.zig");
const file_write = @import("file_write.zig");
const file_edit = @import("file_edit.zig");

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    err: ?[]const u8 = null,
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: std.json.Value,
};

pub const ToolTag = enum {
    file_read,
    file_write,
    file_edit,
};

pub const Tool = union(ToolTag) {
    file_read: file_read.FileReadTool,
    file_write: file_write.FileWriteTool,
    file_edit: file_edit.FileEditTool,

    /// The dispatch/LLM-facing name, derived directly from the active tag
    /// so it can never drift from what registry.find() matches against.
    /// Every concrete tool's spec().name must equal this (see
    /// test/registry_test.zig).
    pub fn name(self: Tool) []const u8 {
        return @tagName(self);
    }

    pub fn spec(self: Tool, allocator: std.mem.Allocator) !ToolSpec {
        return switch (self) {
            inline else => |t| t.spec(allocator),
        };
    }

    pub fn execute(
        self: Tool,
        allocator: std.mem.Allocator,
        io: std.Io,
        policy: *const sandbox.SecurityPolicy,
        args: std.json.Value,
    ) !ToolResult {
        return switch (self) {
            inline else => |t| t.execute(allocator, io, policy, args),
        };
    }
};
