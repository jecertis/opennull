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
    /// Stream the reply as server-sent events instead of one JSON body.
    stream: bool = false,
};

pub const StopReason = enum { end_turn, tool_use, max_tokens, other };

/// Token accounting as reported by the provider API (both Anthropic and
/// OpenAI-compatible endpoints carry it, under different wire names).
pub const Usage = struct {
    input_tokens: u32,
    output_tokens: u32,
};

/// Live observations while a streamed chat response arrives. Text slices
/// are only valid during the sink call (they alias the decode buffer);
/// copy if retaining. The COMPLETE response is still handed back by the
/// streaming call itself, so callers needing the whole text can ignore
/// these and use the return value.
pub const StreamEvent = union(enum) {
    /// An increment of assistant text.
    text: []const u8,
    /// A tool_use block opened; its input arrives as later JSON fragments.
    tool_use_started: struct { id: []const u8, name: []const u8 },
};

/// Push-style sink for stream events (same vtable style as Reporter).
pub const StreamSink = struct {
    ptr: *anyopaque,
    eventFn: *const fn (ptr: *anyopaque, ev: StreamEvent) void,

    pub fn event(self: StreamSink, ev: StreamEvent) void {
        self.eventFn(self.ptr, ev);
    }
};

/// Owns the parsed-JSON arena backing `content`'s strings/values (when
/// built from a real response) — call `deinit()` when done with it.
pub const ChatResponse = struct {
    content: []const ContentBlock,
    stop_reason: StopReason,
    /// Present when the provider reported token usage for this request.
    usage: ?Usage = null,
    _raw: ?std.json.Parsed(std.json.Value) = null,

    pub fn deinit(self: *ChatResponse) void {
        if (self._raw) |*r| r.deinit();
    }
};

/// Concatenates every `.text` content block of a response, skipping
/// tool_use/tool_result blocks. Shared by the one-shot CLI, the chat
/// session, and any future TUI. Caller frees the returned slice.
pub fn extractText(allocator: std.mem.Allocator, response: ChatResponse) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (response.content) |block| {
        switch (block) {
            .text => |t| try buf.appendSlice(allocator, t),
            else => {},
        }
    }
    return buf.toOwnedSlice(allocator);
}

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
    /// Optional incremental variant backing streamed chats. Transports
    /// without it yield error.NotSupported from openStream, and callers
    /// fall back to buffered `send`.
    openFn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) anyerror!StreamConnection = null,

    pub fn send(self: Transport, allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
        return self.sendFn(self.ptr, allocator, req);
    }

    pub fn openStream(self: Transport, allocator: std.mem.Allocator, req: HttpRequest) !StreamConnection {
        const f = self.openFn orelse return error.NotSupported;
        return f(self.ptr, allocator, req);
    }
};

/// A live HTTP response being consumed line by line (SSE). Lines alias an
/// internal buffer and stay valid only until the next `nextLine` call.
/// Errors mean the connection is dead.
pub const StreamConnection = struct {
    ptr: *anyopaque,
    nextLineFn: *const fn (ptr: *anyopaque) anyerror!?[]const u8,
    deinitFn: *const fn (ptr: *anyopaque) void,

    /// Next raw line without its delimiter; null only on clean end of
    /// body between lines.
    pub fn nextLine(self: StreamConnection) anyerror!?[]const u8 {
        return self.nextLineFn(self.ptr);
    }

    pub fn deinit(self: StreamConnection) void {
        self.deinitFn(self.ptr);
    }
};
