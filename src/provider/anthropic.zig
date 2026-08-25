//! Anthropic Messages API provider. Hand-rolls request-body JSON (rather
//! than std.json.Stringify) so ContentBlock/ToolSpec serialization stays
//! simple and fully under our control; uses std.json's dynamic parser for
//! responses, since we don't control that shape. See test/anthropic_test.zig.
const std = @import("std");
const provider = @import("provider.zig");
const json_util = @import("json_util.zig");
const appendJsonString = json_util.appendJsonString;
const appendJsonValue = json_util.appendJsonValue;

pub const AnthropicProvider = struct {
    transport: provider.Transport,
    base_url: []const u8,
    api_key: []const u8,

    pub fn chat(self: AnthropicProvider, allocator: std.mem.Allocator, req: provider.ChatRequest) !provider.ChatResponse {
        const body = try buildRequestBody(allocator, req);
        defer allocator.free(body);

        const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
        defer allocator.free(url);

        const headers = [_]provider.HttpHeader{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "content-type", .value = "application/json" },
        };

        const resp = try self.transport.send(allocator, .{ .url = url, .headers = &headers, .body = body });
        defer allocator.free(resp.body);

        if (resp.status != 200) return error.ApiError;

        return parseResponseBody(allocator, resp.body);
    }
};

fn roleString(r: provider.Role) []const u8 {
    return switch (r) {
        .user, .tool => "user",
        .assistant => "assistant",
        .system => "user",
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

    if (req.system) |sys| {
        try buf.appendSlice(a, ",\"system\":");
        try appendJsonString(&buf, a, sys);
    }

    try buf.appendSlice(a, ",\"messages\":[");
    for (req.messages, 0..) |msg, mi| {
        if (mi != 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"role\":");
        try appendJsonString(&buf, a, roleString(msg.role));
        try buf.appendSlice(a, ",\"content\":[");
        for (msg.content, 0..) |block, bi| {
            if (bi != 0) try buf.append(a, ',');
            try appendContentBlock(&buf, a, block);
        }
        try buf.appendSlice(a, "]}");
    }
    try buf.append(a, ']');

    if (req.tools.len > 0) {
        try buf.appendSlice(a, ",\"tools\":[");
        for (req.tools, 0..) |t, ti| {
            if (ti != 0) try buf.append(a, ',');
            try buf.appendSlice(a, "{\"name\":");
            try appendJsonString(&buf, a, t.name);
            try buf.appendSlice(a, ",\"description\":");
            try appendJsonString(&buf, a, t.description);
            try buf.appendSlice(a, ",\"input_schema\":");
            try appendJsonValue(&buf, a, t.parameters_schema);
            try buf.append(a, '}');
        }
        try buf.append(a, ']');
    }

    try buf.append(a, '}');
    return buf.toOwnedSlice(a);
}

fn appendContentBlock(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, block: provider.ContentBlock) !void {
    switch (block) {
        .text => |t| {
            try buf.appendSlice(a, "{\"type\":\"text\",\"text\":");
            try appendJsonString(buf, a, t);
            try buf.append(a, '}');
        },
        .tool_use => |tu| {
            try buf.appendSlice(a, "{\"type\":\"tool_use\",\"id\":");
            try appendJsonString(buf, a, tu.id);
            try buf.appendSlice(a, ",\"name\":");
            try appendJsonString(buf, a, tu.name);
            try buf.appendSlice(a, ",\"input\":");
            try appendJsonValue(buf, a, tu.input);
            try buf.append(a, '}');
        },
        .tool_result => |tr| {
            try buf.appendSlice(a, "{\"type\":\"tool_result\",\"tool_use_id\":");
            try appendJsonString(buf, a, tr.tool_use_id);
            try buf.appendSlice(a, ",\"content\":");
            try appendJsonString(buf, a, tr.content);
            if (tr.is_error) try buf.appendSlice(a, ",\"is_error\":true");
            try buf.append(a, '}');
        },
    }
}

fn parseResponseBody(allocator: std.mem.Allocator, body: []const u8) !provider.ChatResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    errdefer parsed.deinit();
    const arena_alloc = parsed.arena.allocator();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.UnexpectedResponseShape,
    };

    const content_arr = switch (root_obj.get("content") orelse return error.UnexpectedResponseShape) {
        .array => |arr| arr,
        else => return error.UnexpectedResponseShape,
    };

    const blocks = try arena_alloc.alloc(provider.ContentBlock, content_arr.items.len);
    for (content_arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.UnexpectedResponseShape,
        };
        const block_type = switch (obj.get("type") orelse return error.UnexpectedResponseShape) {
            .string => |s| s,
            else => return error.UnexpectedResponseShape,
        };

        if (std.mem.eql(u8, block_type, "text")) {
            const text = switch (obj.get("text") orelse return error.UnexpectedResponseShape) {
                .string => |s| s,
                else => return error.UnexpectedResponseShape,
            };
            blocks[i] = .{ .text = text };
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            const id = switch (obj.get("id") orelse return error.UnexpectedResponseShape) {
                .string => |s| s,
                else => return error.UnexpectedResponseShape,
            };
            const name = switch (obj.get("name") orelse return error.UnexpectedResponseShape) {
                .string => |s| s,
                else => return error.UnexpectedResponseShape,
            };
            const input = obj.get("input") orelse std.json.Value{ .object = .empty };
            blocks[i] = .{ .tool_use = .{ .id = id, .name = name, .input = input } };
        } else {
            return error.UnexpectedResponseShape;
        }
    }

    const stop_reason_str = switch (root_obj.get("stop_reason") orelse std.json.Value{ .string = "end_turn" }) {
        .string => |s| s,
        .null => "end_turn",
        else => return error.UnexpectedResponseShape,
    };
    const stop_reason: provider.StopReason = if (std.mem.eql(u8, stop_reason_str, "end_turn"))
        .end_turn
    else if (std.mem.eql(u8, stop_reason_str, "tool_use"))
        .tool_use
    else if (std.mem.eql(u8, stop_reason_str, "max_tokens"))
        .max_tokens
    else
        .other;

    return provider.ChatResponse{ .content = blocks, .stop_reason = stop_reason, ._raw = parsed };
}
