//! OpenAI-compatible chat/completions provider. A deliberately different
//! wire shape from anthropic.zig (Bearer auth, role="tool" messages instead
//! of tool_result content blocks, JSON-string-encoded tool_call arguments)
//! to prove the neutral ChatRequest/ChatResponse abstraction really is
//! provider-neutral. See test/openai_compat_test.zig.
const std = @import("std");
const provider = @import("provider.zig");
const json_util = @import("json_util.zig");
const appendJsonString = json_util.appendJsonString;
const appendJsonValue = json_util.appendJsonValue;

pub const OpenAiCompatProvider = struct {
    transport: provider.Transport,
    base_url: []const u8,
    api_key: []const u8,

    pub fn chat(self: OpenAiCompatProvider, allocator: std.mem.Allocator, req: provider.ChatRequest) !provider.ChatResponse {
        const body = try buildRequestBody(allocator, req);
        defer allocator.free(body);

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
        defer allocator.free(url);

        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(auth);

        const headers = [_]provider.HttpHeader{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
        };

        const resp = try self.transport.send(allocator, .{ .url = url, .headers = &headers, .body = body });
        defer allocator.free(resp.body);

        if (resp.status != 200) return error.ApiError;

        return parseResponseBody(allocator, resp.body);
    }

    /// Streaming arrives in a later cycle; until then the loop's fallback
    /// path uses plain chat.
    pub fn chatStreaming(
        self: OpenAiCompatProvider,
        allocator: std.mem.Allocator,
        req: provider.ChatRequest,
        sink: provider.StreamSink,
    ) !provider.ChatResponse {
        _ = self;
        _ = allocator;
        _ = req;
        _ = sink;
        return error.NotSupported;
    }
};

fn roleString(r: provider.Role) []const u8 {
    return switch (r) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn buildRequestBody(a: std.mem.Allocator, req: provider.ChatRequest) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "{\"model\":");
    try appendJsonString(&buf, a, req.model);
    try buf.appendSlice(a, ",\"max_tokens\":");
    const mt = try std.fmt.allocPrint(a, "{d}", .{req.max_tokens});
    defer a.free(mt);
    try buf.appendSlice(a, mt);

    try buf.appendSlice(a, ",\"messages\":[");
    var wrote_msg = false;

    if (req.system) |sys| {
        try buf.appendSlice(a, "{\"role\":\"system\",\"content\":");
        try appendJsonString(&buf, a, sys);
        try buf.append(a, '}');
        wrote_msg = true;
    }

    for (req.messages) |msg| {
        if (msg.role == .tool) {
            // OpenAI represents each tool result as its own message, not a
            // content block — emit one per tool_result in this Message.
            for (msg.content) |block| {
                switch (block) {
                    .tool_result => |tr| {
                        if (wrote_msg) try buf.append(a, ',');
                        wrote_msg = true;
                        try buf.appendSlice(a, "{\"role\":\"tool\",\"tool_call_id\":");
                        try appendJsonString(&buf, a, tr.tool_use_id);
                        try buf.appendSlice(a, ",\"content\":");
                        try appendJsonString(&buf, a, tr.content);
                        try buf.append(a, '}');
                    },
                    else => {},
                }
            }
            continue;
        }

        if (wrote_msg) try buf.append(a, ',');
        wrote_msg = true;

        try buf.appendSlice(a, "{\"role\":");
        try appendJsonString(&buf, a, roleString(msg.role));

        var text_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer text_buf.deinit(a);
        for (msg.content) |block| {
            switch (block) {
                .text => |t| try text_buf.appendSlice(a, t),
                else => {},
            }
        }
        try buf.appendSlice(a, ",\"content\":");
        try appendJsonString(&buf, a, text_buf.items);

        var has_tool_use = false;
        for (msg.content) |block| {
            if (block == .tool_use) {
                has_tool_use = true;
                break;
            }
        }
        if (has_tool_use) {
            try buf.appendSlice(a, ",\"tool_calls\":[");
            var first_tc = true;
            for (msg.content) |block| {
                switch (block) {
                    .tool_use => |tu| {
                        if (!first_tc) try buf.append(a, ',');
                        first_tc = false;
                        try buf.appendSlice(a, "{\"id\":");
                        try appendJsonString(&buf, a, tu.id);
                        try buf.appendSlice(a, ",\"type\":\"function\",\"function\":{\"name\":");
                        try appendJsonString(&buf, a, tu.name);
                        try buf.appendSlice(a, ",\"arguments\":");
                        const args_str = try json_util.valueToOwnedString(a, tu.input);
                        defer a.free(args_str);
                        try appendJsonString(&buf, a, args_str);
                        try buf.appendSlice(a, "}}");
                    },
                    else => {},
                }
            }
            try buf.append(a, ']');
        }
        try buf.append(a, '}');
    }
    try buf.append(a, ']');

    if (req.tools.len > 0) {
        try buf.appendSlice(a, ",\"tools\":[");
        for (req.tools, 0..) |t, ti| {
            if (ti != 0) try buf.append(a, ',');
            try buf.appendSlice(a, "{\"type\":\"function\",\"function\":{\"name\":");
            try appendJsonString(&buf, a, t.name);
            try buf.appendSlice(a, ",\"description\":");
            try appendJsonString(&buf, a, t.description);
            try buf.appendSlice(a, ",\"parameters\":");
            try appendJsonValue(&buf, a, t.parameters_schema);
            try buf.appendSlice(a, "}}");
        }
        try buf.append(a, ']');
    }

    try buf.append(a, '}');
    return buf.toOwnedSlice(a);
}

fn parseResponseBody(allocator: std.mem.Allocator, body: []const u8) !provider.ChatResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    errdefer parsed.deinit();
    const arena_alloc = parsed.arena.allocator();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.UnexpectedResponseShape,
    };
    const choices = switch (root_obj.get("choices") orelse return error.UnexpectedResponseShape) {
        .array => |arr| arr,
        else => return error.UnexpectedResponseShape,
    };
    if (choices.items.len == 0) return error.UnexpectedResponseShape;
    const choice = switch (choices.items[0]) {
        .object => |o| o,
        else => return error.UnexpectedResponseShape,
    };
    const message = switch (choice.get("message") orelse return error.UnexpectedResponseShape) {
        .object => |o| o,
        else => return error.UnexpectedResponseShape,
    };

    var blocks: std.ArrayListUnmanaged(provider.ContentBlock) = .empty;

    if (message.get("content")) |content_val| {
        switch (content_val) {
            .string => |s| if (s.len > 0) try blocks.append(arena_alloc, .{ .text = s }),
            .null => {},
            else => return error.UnexpectedResponseShape,
        }
    }

    if (message.get("tool_calls")) |tool_calls_val| {
        const tool_calls_arr = switch (tool_calls_val) {
            .array => |arr| arr,
            else => return error.UnexpectedResponseShape,
        };
        for (tool_calls_arr.items) |call| {
            const call_obj = switch (call) {
                .object => |o| o,
                else => return error.UnexpectedResponseShape,
            };
            const id = switch (call_obj.get("id") orelse return error.UnexpectedResponseShape) {
                .string => |s| s,
                else => return error.UnexpectedResponseShape,
            };
            const func = switch (call_obj.get("function") orelse return error.UnexpectedResponseShape) {
                .object => |o| o,
                else => return error.UnexpectedResponseShape,
            };
            const name = switch (func.get("name") orelse return error.UnexpectedResponseShape) {
                .string => |s| s,
                else => return error.UnexpectedResponseShape,
            };
            const args_str = switch (func.get("arguments") orelse return error.UnexpectedResponseShape) {
                .string => |s| s,
                else => return error.UnexpectedResponseShape,
            };
            const input = std.json.parseFromSliceLeaky(std.json.Value, arena_alloc, args_str, .{}) catch
                return error.UnexpectedResponseShape;

            try blocks.append(arena_alloc, .{ .tool_use = .{ .id = id, .name = name, .input = input } });
        }
    }

    const finish_reason = switch (choice.get("finish_reason") orelse std.json.Value{ .string = "stop" }) {
        .string => |s| s,
        .null => "stop",
        else => return error.UnexpectedResponseShape,
    };
    const stop_reason: provider.StopReason = if (std.mem.eql(u8, finish_reason, "stop"))
        .end_turn
    else if (std.mem.eql(u8, finish_reason, "tool_calls"))
        .tool_use
    else if (std.mem.eql(u8, finish_reason, "length"))
        .max_tokens
    else
        .other;

    return provider.ChatResponse{
        .content = try blocks.toOwnedSlice(arena_alloc),
        .stop_reason = stop_reason,
        .usage = parseUsage(root_obj),
        ._raw = parsed,
    };
}

/// OpenAI wire shape: "usage": {"prompt_tokens": N, "completion_tokens": M}.
/// Absent or malformed usage simply yields null — accounting is optional.
fn parseUsage(root_obj: std.json.ObjectMap) ?provider.Usage {
    const usage_val = root_obj.get("usage") orelse return null;
    const usage_obj = switch (usage_val) {
        .object => |o| o,
        else => return null,
    };
    const prompt_tok = switch (usage_obj.get("prompt_tokens") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    const completion_tok = switch (usage_obj.get("completion_tokens") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    if (prompt_tok < 0 or completion_tok < 0) return null;
    return .{ .input_tokens = @intCast(prompt_tok), .output_tokens = @intCast(completion_tok) };
}
