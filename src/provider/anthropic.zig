//! Anthropic Messages API provider. Hand-rolls request-body JSON (rather
//! than std.json.Stringify) so ContentBlock/ToolSpec serialization stays
//! simple and fully under our control; uses std.json's dynamic parser for
//! responses, since we don't control that shape. See test/anthropic_test.zig.
const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
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

        return self.send(allocator, url, &headers, body);
    }

    fn send(self: AnthropicProvider, allocator: std.mem.Allocator, url: []const u8, headers: []const provider.HttpHeader, body: []const u8) !provider.ChatResponse {
        const resp = try self.transport.send(allocator, .{ .url = url, .headers = headers, .body = body });
        defer allocator.free(resp.body);

        if (resp.status != 200) return error.ApiError;

        return parseResponseBody(allocator, resp.body);
    }

    /// Streamed variant of chat: text deltas (and tool_use openings) are
    /// pushed to `sink` as they arrive, AND the complete assembled response
    /// is returned — callers keep the exact non-streaming semantics. Falls
    /// back to buffered chat when the transport cannot stream.
    pub fn chatStreaming(
        self: AnthropicProvider,
        allocator: std.mem.Allocator,
        req_in: provider.ChatRequest,
        sink: provider.StreamSink,
    ) !provider.ChatResponse {
        var req = req_in;
        req.stream = true;

        const body = try buildRequestBody(allocator, req);
        defer allocator.free(body);

        const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
        defer allocator.free(url);

        const headers = [_]provider.HttpHeader{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "content-type", .value = "application/json" },
        };

        const conn = try self.transport.openStream(allocator, .{ .url = url, .headers = &headers, .body = body });
        defer conn.deinit();

        // Deliberately NO deinit on this decoder: the assembled response
        // references its memory, which belongs to the caller's
        // bulk-reclaim allocator (same ownership rule as loop.runTurn).
        var decoder = StreamDecoder.init(allocator, sink);
        while (try conn.nextLine()) |line| try decoder.feedLine(line);
        return decoder.buildResponse();
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

    if (req.stream) try buf.appendSlice(a, ",\"stream\":true");

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

    return provider.ChatResponse{
        .content = blocks,
        .stop_reason = stop_reason,
        .usage = parseUsage(root_obj),
        ._raw = parsed,
    };
}

/// Anthropic wire shape: "usage": {"input_tokens": N, "output_tokens": M}.
/// Absent or malformed usage simply yields null — accounting is optional.
fn parseUsage(root_obj: std.json.ObjectMap) ?provider.Usage {
    const usage_val = root_obj.get("usage") orelse return null;
    const usage_obj = switch (usage_val) {
        .object => |o| o,
        else => return null,
    };
    const in_tok = switch (usage_obj.get("input_tokens") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    const out_tok = switch (usage_obj.get("output_tokens") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    if (in_tok < 0 or out_tok < 0) return null;
    return .{ .input_tokens = @intCast(in_tok), .output_tokens = @intCast(out_tok) };
}

/// Decodes Anthropic's streaming SSE protocol into neutral StreamEvents
/// while assembling the complete ChatResponse incrementally — the streamed
/// call still returns a whole response at the end, so callers (the agent
/// loop) keep their existing semantics. Ownership mirrors parseResponseBody:
/// all strings live in the bulk-reclaim allocator you pass in. See
/// test/sse_test.zig.
pub const StreamDecoder = struct {
    const BlockKind = enum { none, text, tool_use };

    allocator: std.mem.Allocator,
    sse: sse.Decoder,

    blocks: std.ArrayListUnmanaged(provider.ContentBlock) = .empty,
    block_kind: BlockKind = .none,
    text_buf: std.ArrayListUnmanaged(u8) = .empty,
    tool_id: std.ArrayListUnmanaged(u8) = .empty,
    tool_name: std.ArrayListUnmanaged(u8) = .empty,
    tool_json: std.ArrayListUnmanaged(u8) = .empty,
    stop_reason: ?provider.StopReason = null,
    usage: ?provider.Usage = null,

    sink: ?provider.StreamSink = null,

    pub fn init(allocator: std.mem.Allocator, sink: ?provider.StreamSink) StreamDecoder {
        return .{ .allocator = allocator, .sse = .{ .allocator = allocator }, .sink = sink };
    }

    pub fn deinit(self: *StreamDecoder) void {
        self.sse.deinit();
        self.blocks.deinit(self.allocator);
        self.text_buf.deinit(self.allocator);
        self.tool_id.deinit(self.allocator);
        self.tool_name.deinit(self.allocator);
        self.tool_json.deinit(self.allocator);
    }

    fn emit(self: *StreamDecoder, ev: provider.StreamEvent) void {
        if (self.sink) |s| s.event(ev);
    }

    /// Feeds one raw HTTP-body line. Errors only on allocation failure or a
    /// data payload that is not valid JSON with the expected shape.
    pub fn feedLine(self: *StreamDecoder, line: []const u8) !void {
        const decoded = (try self.sse.feedLine(line)) orelse return;
        try self.handleDecoded(decoded.event, decoded.data);
    }

    fn handleDecoded(self: *StreamDecoder, event: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, event, "ping")) return;

        const obj = switch (try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, data, .{})) {
            .object => |o| o,
            else => return error.UnexpectedStreamEvent,
        };

        if (std.mem.eql(u8, event, "content_block_start")) {
            const block = switch (obj.get("content_block") orelse return error.UnexpectedStreamEvent) {
                .object => |o| o,
                else => return error.UnexpectedStreamEvent,
            };
            const kind = switch (block.get("type") orelse return error.UnexpectedStreamEvent) {
                .string => |s| s,
                else => return error.UnexpectedStreamEvent,
            };
            if (std.mem.eql(u8, kind, "tool_use")) {
                self.block_kind = .tool_use;
                const id = switch (block.get("id") orelse return error.UnexpectedStreamEvent) {
                    .string => |s| s,
                    else => return error.UnexpectedStreamEvent,
                };
                const name = switch (block.get("name") orelse return error.UnexpectedStreamEvent) {
                    .string => |s| s,
                    else => return error.UnexpectedStreamEvent,
                };
                try self.tool_id.appendSlice(self.allocator, id);
                try self.tool_name.appendSlice(self.allocator, name);
                self.emit(.{ .tool_use_started = .{ .id = id, .name = name } });
            } else if (std.mem.eql(u8, kind, "text")) {
                self.block_kind = .text;
            } else {
                self.block_kind = .none;
            }
            return;
        }

        if (std.mem.eql(u8, event, "content_block_delta")) {
            const delta = switch (obj.get("delta") orelse return error.UnexpectedStreamEvent) {
                .object => |o| o,
                else => return error.UnexpectedStreamEvent,
            };
            const dtype = switch (delta.get("type") orelse return error.UnexpectedStreamEvent) {
                .string => |s| s,
                else => return error.UnexpectedStreamEvent,
            };
            if (std.mem.eql(u8, dtype, "text_delta")) {
                const text = switch (delta.get("text") orelse return error.UnexpectedStreamEvent) {
                    .string => |s| s,
                    else => return error.UnexpectedStreamEvent,
                };
                try self.text_buf.appendSlice(self.allocator, text);
                self.emit(.{ .text = text });
            } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
                const frag = switch (delta.get("partial_json") orelse return error.UnexpectedStreamEvent) {
                    .string => |s| s,
                    else => return error.UnexpectedStreamEvent,
                };
                try self.tool_json.appendSlice(self.allocator, frag);
            }
            return;
        }

        if (std.mem.eql(u8, event, "content_block_stop")) {
            switch (self.block_kind) {
                .text => try self.blocks.append(self.allocator, .{
                    // Dupe before clearing: blocks must own their bytes even
                    // though these buffers are reused by the next block.
                    .text = try self.allocator.dupe(u8, self.text_buf.items),
                }),
                .tool_use => {
                    const input = std.json.parseFromSliceLeaky(
                        std.json.Value,
                        self.allocator,
                        self.tool_json.items,
                        .{},
                    ) catch std.json.Value{ .object = .empty };
                    try self.blocks.append(self.allocator, .{ .tool_use = .{
                        .id = try self.allocator.dupe(u8, self.tool_id.items),
                        .name = try self.allocator.dupe(u8, self.tool_name.items),
                        .input = input,
                    } });
                },
                .none => {},
            }
            self.block_kind = .none;
            self.text_buf.clearRetainingCapacity();
            self.tool_id.clearRetainingCapacity();
            self.tool_name.clearRetainingCapacity();
            self.tool_json.clearRetainingCapacity();
            return;
        }

        if (std.mem.eql(u8, event, "message_delta")) {
            const delta = switch (obj.get("delta") orelse return error.UnexpectedStreamEvent) {
                .object => |o| o,
                else => return error.UnexpectedStreamEvent,
            };
            if (delta.get("stop_reason")) |sr| switch (sr) {
                .string => |s| {
                    self.stop_reason = if (std.mem.eql(u8, s, "end_turn"))
                        .end_turn
                    else if (std.mem.eql(u8, s, "tool_use"))
                        .tool_use
                    else if (std.mem.eql(u8, s, "max_tokens"))
                        .max_tokens
                    else
                        .other;
                },
                else => {},
            };
            if (obj.get("usage")) |u| switch (u) {
                .object => |uo| {
                    const in_tok: i64 = if (uo.get("input_tokens")) |v| switch (v) {
                        .integer => |n| n,
                        else => 0,
                    } else 0;
                    const out_tok: i64 = if (uo.get("output_tokens")) |v| switch (v) {
                        .integer => |n| n,
                        else => 0,
                    } else 0;
                    if (in_tok >= 0 and out_tok >= 0 and (in_tok > 0 or out_tok > 0)) {
                        self.usage = .{
                            .input_tokens = @intCast(in_tok),
                            .output_tokens = @intCast(out_tok),
                        };
                    }
                },
                else => {},
            };
            return;
        }

        // message_start / message_stop / others carry nothing we need.
    }

    /// Builds the complete response from accumulated blocks. Call after the
    /// stream ends. The returned ChatResponse does NOT own `_raw` — its
    /// strings live directly in this decoder's bulk-reclaim allocator.
    pub fn buildResponse(self: *StreamDecoder) provider.ChatResponse {
        return .{
            .content = self.blocks.items,
            .stop_reason = self.stop_reason orelse .end_turn,
            .usage = self.usage,
            ._raw = null,
        };
    }
};
