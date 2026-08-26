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
            .tool_use_started => |t| self.events.append(self.allocator, .{ .tool_use_started = .{
                .id = t.id,
                .name = t.name,
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
