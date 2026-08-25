//! Provider-neutral chat types shared by every concrete provider
//! (anthropic.zig, later openai_compat.zig) and by the agent loop. This is
//! the seam that lets the router swap providers without the agent loop
//! caring about wire-format differences.
const std = @import("std");

pub const Role = enum { system, user, assistant, tool };

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

pub const ToolResultBlock = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResultBlock,
};

pub const Message = struct {
    role: Role,
    content: []const ContentBlock,
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: std.json.Value,
};

pub const ChatRequest = struct {
    model: []const u8,
    system: ?[]const u8 = null,
    messages: []const Message,
    tools: []const ToolSpec = &.{},
    max_tokens: u32 = 4096,
};

pub const StopReason = enum { end_turn, tool_use, max_tokens, other };

/// Owns the parsed-JSON arena backing `content`'s strings/values (when
/// built from a real response) — call `deinit()` when done with it.
pub const ChatResponse = struct {
    content: []const ContentBlock,
    stop_reason: StopReason,
    _raw: ?std.json.Parsed(std.json.Value) = null,

    pub fn deinit(self: *ChatResponse) void {
        if (self._raw) |*r| r.deinit();
    }
};

// -- transport (injectable so providers are unit-testable without a real
//    network call) -------------------------------------------------------

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    url: []const u8,
    headers: []const HttpHeader,
    body: []const u8,
};

pub const HttpResponse = struct {
    status: u16,
    /// Allocator-owned; the caller (a provider's `chat`) frees it.
    body: []const u8,
};

pub const Transport = struct {
    ptr: *anyopaque,
    sendFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) anyerror!HttpResponse,

    pub fn send(self: Transport, allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
        return self.sendFn(self.ptr, allocator, req);
    }
};
