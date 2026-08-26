//! BDD specs for streaming: src/provider/sse.zig (SSE line framing) and
//! src/provider/anthropic.zig's StreamDecoder (Anthropic stream protocol →
//! neutral events + assembled ChatResponse). All offline: lines are pushed
//! exactly as they would arrive from an HTTP body.
const std = @import("std");
const opennull = @import("opennull");
const provider = opennull.provider.core;
const sse = opennull.provider.sse;
const anthropic = opennull.provider.anthropic;

// -- SSE framing ---------------------------------------------------------

fn decodeLines(arena: std.mem.Allocator, lines: []const []const u8) ![]sse.Decoded {
    var dec = sse.Decoder{ .allocator = arena };
    var out: std.ArrayListUnmanaged(sse.Decoded) = .empty;
    for (lines) |l| {
        if (try dec.feedLine(l)) |d| try out.append(arena, d);
    }
    return out.toOwnedSlice(arena);
}

// Scenario: Given standard event/data/blank-line framing, when decoded,
// then each blank line yields one event with its name and payload.
test "decodes a basic event block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const events = try decodeLines(arena.allocator(), &.{
        "event: content_block_delta",
        "data: {\"delta\":1}",
        "",
    });

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("content_block_delta", events[0].event);
    try std.testing.expectEqualStrings("{\"delta\":1}", events[0].data);
}

// Scenario: Given keepalive comment lines, when fed, then they produce no
// events — pings must not disturb decoding.
test "comment lines are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const events = try decodeLines(arena.allocator(), &.{
        ": ping",
        "event: message_start",
        "",
        ": another comment",
        "",
    });

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("message_start", events[0].event);
}

// Scenario: Given several data lines in one event, when decoded, then they
// join with a single newline per the SSE spec.
test "multiple data lines join with newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const events = try decodeLines(arena.allocator(), &.{
        "data: first",
        "data: second",
        "",
    });

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("", events[0].event);
    try std.testing.expectEqualStrings("first\nsecond", events[0].data);
}

// Scenario: Given CRLF line endings (some proxies), when fed raw, then the
// trailing \r is stripped and framing still works.
test "CRLF endings are tolerated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const events = try decodeLines(arena.allocator(), &.{
        "event: ping\r",
        "data: {}\r",
        "\r",
    });

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ping", events[0].event);
}

// -- Anthropic stream decoding -------------------------------------------

const CollectedEvent = union(enum) {
    text: []const u8,
    tool_use_started: struct { id: []const u8, name: []const u8 },
};

/// Records neutral StreamEvents (copies text so later buffer reuse in the
/// test cannot confuse assertions).
const RecordingSink = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(CollectedEvent) = .empty,

    fn sink(self: *RecordingSink) provider.StreamSink {
        return .{ .ptr = self, .eventFn = event };
    }

    fn event(ptr: *anyopaque, ev: provider.StreamEvent) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .text => |t| self.events.append(self.allocator, .{ .text = self.allocator.dupe(u8, t) catch @panic("OOM") }) catch @panic("OOM"),
            // The sink contract: slices are only valid during this call —
            // copy them, the decoder's buffers keep growing.
            .tool_use_started => |t| self.events.append(self.allocator, .{ .tool_use_started = .{
                .id = self.allocator.dupe(u8, t.id) catch @panic("OOM"),
                .name = self.allocator.dupe(u8, t.name) catch @panic("OOM"),
            } }) catch @panic("OOM"),
        }
    }
};

fn feedAll(dec: *anthropic.StreamDecoder, lines: []const []const u8) !void {
    for (lines) |l| try dec.feedLine(l);
}

// Scenario: Given a streamed text answer (message_start ignored, two
// text_delta chunks, message_delta with stop reason and usage), when
// decoded, then live text events carry each chunk AND buildResponse yields
// the complete text response.
test "text stream emits live deltas and assembles the full response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = RecordingSink{ .allocator = a };
    defer recorder.events.deinit(a);
    var dec = anthropic.StreamDecoder.init(a, recorder.sink());
    defer dec.deinit();

    try feedAll(&dec, &.{
        "event: message_start",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}",
        "",
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \"}}",
        "",
        ": keepalive mid-stream",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}",
        "",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":0}",
        "",
        "event: message_delta",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}",
        "",
        "event: message_stop",
        "data: {\"type\":\"message_stop\"}",
        "",
    });

    // Live events: exactly the two text increments.
    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("Hello ", recorder.events.items[0].text);
    try std.testing.expectEqualStrings("world", recorder.events.items[1].text);

    const resp = dec.buildResponse();
    try std.testing.expectEqual(provider.StopReason.end_turn, resp.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expectEqualStrings("Hello world", resp.content[0].text);
    const u = resp.usage.?;
    try std.testing.expectEqual(@as(u32, 5), u.output_tokens);
}

// Scenario: Given a streamed tool_use turn (block start carries id/name,
// input arrives as partial_json fragments), when decoded, then a live
// tool_use_started fires and buildResponse holds the assembled tool_use
// block with PARSED input ready for dispatch.
test "tool_use stream assembles id, name and parsed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = RecordingSink{ .allocator = a };
    defer recorder.events.deinit(a);
    var dec = anthropic.StreamDecoder.init(a, recorder.sink());
    defer dec.deinit();

    try feedAll(&dec, &.{
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_9\",\"name\":\"file_read\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"a.txt\\\"}\"}}",
        "",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":0}",
        "",
        "event: message_delta",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}",
        "",
    });

    try std.testing.expectEqual(@as(usize, 1), recorder.events.items.len);
    const started = recorder.events.items[0].tool_use_started;
    try std.testing.expectEqualStrings("call_9", started.id);
    try std.testing.expectEqualStrings("file_read", started.name);

    const resp = dec.buildResponse();
    try std.testing.expectEqual(provider.StopReason.tool_use, resp.stop_reason);
    const tu = resp.content[0].tool_use;
    try std.testing.expectEqualStrings("call_9", tu.id);
    try std.testing.expectEqualStrings("file_read", tu.name);
    try std.testing.expectEqualStrings("a.txt", tu.input.object.get("path").?.string);
}

// Scenario: Given a mixed turn (one text block then one tool_use block),
// when decoded, then buildResponse preserves block ORDER — the agent loop
// depends on text preceding tool calls exactly as sent.
test "mixed blocks preserve order in the built response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dec = anthropic.StreamDecoder.init(a, null);
    defer dec.deinit();

    try feedAll(&dec, &.{
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"let me check\"}}",
        "",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":0}",
        "",
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"file_edit\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}",
        "",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":1}",
        "",
    });

    const resp = dec.buildResponse();
    try std.testing.expectEqual(@as(usize, 2), resp.content.len);
    try std.testing.expectEqualStrings("let me check", resp.content[0].text);
    try std.testing.expectEqualStrings("file_edit", resp.content[1].tool_use.name);
}

// Scenario: Given TWO consecutive text blocks, when decoded, then their
// contents stay separate — clearing between blocks must not leak bytes
// from one block into the next.
test "consecutive text blocks do not bleed into each other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dec = anthropic.StreamDecoder.init(a, null);
    defer dec.deinit();

    try feedAll(&dec, &.{
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"first block\"}}",
        "",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":0}",
        "",
        "event: content_block_start",
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\"}}",
        "",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"second\"}}",
        "",
        "event: content_block_stop",
        "data: {\"type\":\"content_block_stop\",\"index\":1}",
        "",
    });

    const resp = dec.buildResponse();
    try std.testing.expectEqual(@as(usize, 2), resp.content.len);
    try std.testing.expectEqualStrings("first block", resp.content[0].text);
    try std.testing.expectEqualStrings("second", resp.content[1].text);
}

// -- provider-level streaming --------------------------------------------

/// Transport whose openFn serves a scripted SSE line sequence and captures
/// the outgoing request body. `send` is never expected on this transport.
const ScriptedStreamTransport = struct {
    lines: []const []const u8,
    captured_body: []u8 = "",
    allocator: std.mem.Allocator,

    fn transport(self: *ScriptedStreamTransport) provider.Transport {
        return .{ .ptr = self, .sendFn = unexpectedSend, .openFn = open };
    }

    fn unexpectedSend(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.HttpResponse {
        _ = ptr;
        _ = allocator;
        _ = req;
        @panic("buffered send must not run when streaming is available");
    }

    fn open(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.StreamConnection {
        const self: *ScriptedStreamTransport = @ptrCast(@alignCast(ptr));
        self.captured_body = try allocator.dupe(u8, req.body);
        return .{ .ptr = self, .nextLineFn = nextLine, .deinitFn = deinitStream };
    }

    fn nextLine(ptr: *anyopaque) anyerror!?[]const u8 {
        const self: *ScriptedStreamTransport = @ptrCast(@alignCast(ptr));
        if (self.lines.len == 0) return null;
        const line = self.lines[0];
        self.lines = self.lines[1..];
        return line;
    }

    fn deinitStream(ptr: *anyopaque) void {
        _ = ptr;
    }
};

// Scenario: Given a transport that streams SSE lines, when chatStreaming
// runs, then the request carries "stream":true, live deltas reach the sink,
// AND the fully assembled response comes back with stop reason and usage.
test "chatStreaming sends stream flag, emits deltas, returns complete response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = ScriptedStreamTransport{
        .allocator = a,
        .lines = &.{
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"He\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"y\"}}",
            "",
            "event: content_block_stop",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "",
            "event: message_delta",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":9,\"output_tokens\":2}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            "",
        },
    };
    const p = anthropic.AnthropicProvider{ .transport = t.transport(), .base_url = "https://api.anthropic.com", .api_key = "k" };

    var recorder = RecordingSink{ .allocator = a };
    defer recorder.events.deinit(a);

    const resp = try p.chatStreaming(a, .{ .model = "m", .messages = &.{} }, recorder.sink());

    try std.testing.expect(std.mem.indexOf(u8, t.captured_body, "\"stream\":true") != null);
    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("He", recorder.events.items[0].text);
    try std.testing.expectEqualStrings("y", recorder.events.items[1].text);

    try std.testing.expectEqual(provider.StopReason.end_turn, resp.stop_reason);
    try std.testing.expectEqualStrings("Hey", resp.content[0].text);
    try std.testing.expectEqual(@as(u32, 9), resp.usage.?.input_tokens);
}

// -- OpenAI-compatible streaming ----------------------------------------

const openai = opennull.provider.openai_compat;

fn feedOpenAi(dec: *openai.StreamDecoder, datas: []const []const u8) !void {
    for (datas) |d| {
        var buf: [512]u8 = undefined;
        _ = try dec.feedLine(try std.fmt.bufPrint(&buf, "data: {s}", .{d}));
        _ = try dec.feedLine("");
    }
    _ = try dec.feedLine("data: [DONE]");
    _ = try dec.feedLine("");
}

// Scenario: Given a nameless-SSE OpenAI stream (content deltas, finish
// reason stop, usage on the final chunk, then [DONE]), when decoded, then
// live text events fire and the assembled response carries the full text
// with prompt/completion tokens mapped to neutral usage.
test "openai text stream decodes deltas, finish reason and usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = RecordingSink{ .allocator = a };
    defer recorder.events.deinit(a);
    var dec = openai.StreamDecoder.init(a, recorder.sink());
    defer dec.deinit();

    try feedOpenAi(&dec, &.{
        "{\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"Good \"}}]}",
        "{\"choices\":[{\"delta\":{\"content\":\"day\"}}]}",
        "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
        "{\"choices\":[],\"usage\":{\"prompt_tokens\":31,\"completion_tokens\":4}}",
        "[DONE]",
    });

    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("Good ", recorder.events.items[0].text);
    try std.testing.expectEqualStrings("day", recorder.events.items[1].text);

    const resp = try dec.buildResponse();
    try std.testing.expectEqual(provider.StopReason.end_turn, resp.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expectEqualStrings("Good day", resp.content[0].text);
    const u = resp.usage.?;
    try std.testing.expectEqual(@as(u32, 31), u.input_tokens);
    try std.testing.expectEqual(@as(u32, 4), u.output_tokens);
}

// Scenario: Given streamed tool_calls where the first fragment carries
// id+name and arguments arrive split across chunks, when decoded, then a
// live tool_use_started fires and the assembled tool_use block has parsed
// input with stop_reason tool_calls.
test "openai tool_calls stream assembles fragments into a dispatchable block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var recorder = RecordingSink{ .allocator = a };
    defer recorder.events.deinit(a);
    var dec = openai.StreamDecoder.init(a, recorder.sink());
    defer dec.deinit();

    try feedOpenAi(&dec, &.{
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_z\",\"function\":{\"name\":\"file_write\",\"arguments\":\"\"}}]}}]}",
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\\\"x\\\",\"}}]}}]}",
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"content\\\":\\\"hi\\\"}\"}}]}}]}",
        "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
        "[DONE]",
    });

    try std.testing.expectEqual(@as(usize, 1), recorder.events.items.len);
    try std.testing.expectEqualStrings("file_write", recorder.events.items[0].tool_use_started.name);

    const resp = try dec.buildResponse();
    try std.testing.expectEqual(provider.StopReason.tool_use, resp.stop_reason);
    const tu = resp.content[0].tool_use;
    try std.testing.expectEqualStrings("call_z", tu.id);
    try std.testing.expectEqualStrings("file_write", tu.name);
    try std.testing.expectEqualStrings("x", tu.input.object.get("path").?.string);
    try std.testing.expectEqualStrings("hi", tu.input.object.get("content").?.string);
}

// Scenario: Given chatStreaming on the openai provider over a scripted
// connection, when it runs, then the request body asks for streaming WITH
// usage included, and the complete response comes back.
test "openai chatStreaming requests include_usage and returns whole response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = ScriptedStreamTransport{
        .allocator = a,
        .lines = &.{
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1}}",
            "",
            "data: [DONE]",
            "",
        },
    };
    const p = openai.OpenAiCompatProvider{ .transport = t.transport(), .base_url = "http://localhost:9", .api_key = "k" };

    var recorder = RecordingSink{ .allocator = a };
    defer recorder.events.deinit(a);

    const resp = try p.chatStreaming(a, .{ .model = "m", .messages = &.{} }, recorder.sink());

    try std.testing.expect(std.mem.indexOf(u8, t.captured_body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.captured_body, "\"include_usage\":true") != null);
    try std.testing.expectEqualStrings("ok", resp.content[0].text);
    try std.testing.expectEqual(@as(u32, 5), resp.usage.?.input_tokens);
}
