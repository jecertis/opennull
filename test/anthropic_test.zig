//! BDD spec for src/provider/anthropic.zig. Uses an injected Transport (a
//! spy/fake, not a real network call) so these run offline and fast; a
//! real-network smoke test against a live API key stays manual (see the
//! plan's Verification section), not part of `zig build test`.
const std = @import("std");
const opennull = @import("opennull");
const provider = opennull.provider.core;
const anthropic = opennull.provider.anthropic;

/// Asserts the request shape synchronously (while it's still alive, before
/// the caller frees it) and returns a canned text response.
const CapturingTransport = struct {
    fn send(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.HttpResponse {
        _ = ptr;
        try std.testing.expect(std.mem.endsWith(u8, req.url, "/v1/messages"));

        var has_api_key = false;
        var has_version = false;
        for (req.headers) |h| {
            if (std.mem.eql(u8, h.name, "x-api-key") and std.mem.eql(u8, h.value, "test-key")) has_api_key = true;
            if (std.mem.eql(u8, h.name, "anthropic-version")) has_version = true;
        }
        try std.testing.expect(has_api_key);
        try std.testing.expect(has_version);
        try std.testing.expect(std.mem.indexOf(u8, req.body, "claude-sonnet-5") != null);
        try std.testing.expect(std.mem.indexOf(u8, req.body, "\"role\":\"user\"") != null);

        const body = "{\"content\":[{\"type\":\"text\",\"text\":\"hi from fake\"}],\"stop_reason\":\"end_turn\"}";
        return .{ .status = 200, .body = try allocator.dupe(u8, body) };
    }

    fn transport() provider.Transport {
        return .{ .ptr = undefined, .sendFn = send };
    }
};

fn oneUserMessage(text: []const u8) [1]provider.Message {
    return .{.{
        .role = .user,
        .content = &.{.{ .text = text }},
    }};
}

// Scenario: Given a chat request, when sent, then it hits the Messages
// endpoint with the api key and version headers and a body naming the
// requested model and the user message role.
test "sends request to the messages endpoint with required headers and body" {
    const p = anthropic.AnthropicProvider{
        .transport = CapturingTransport.transport(),
        .base_url = "https://api.anthropic.com",
        .api_key = "test-key",
    };
    const messages = oneUserMessage("hello");
    var resp = try p.chat(std.testing.allocator, .{
        .model = "claude-sonnet-5",
        .messages = &messages,
    });
    defer resp.deinit();
}

const ScriptedTransport = struct {
    status: u16,
    body: []const u8,

    fn send(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.HttpResponse {
        _ = req;
        const self: *const ScriptedTransport = @ptrCast(@alignCast(ptr));
        return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
    }

    fn transport(self: *const ScriptedTransport) provider.Transport {
        return .{ .ptr = @constCast(self), .sendFn = send };
    }
};

// Scenario: Given a response with a single text content block, when
// parsed, then ChatResponse holds that text and stop_reason end_turn.
test "parses a text-only response" {
    const scripted = ScriptedTransport{
        .status = 200,
        .body = "{\"content\":[{\"type\":\"text\",\"text\":\"hello there\"}],\"stop_reason\":\"end_turn\"}",
    };
    const p = anthropic.AnthropicProvider{
        .transport = scripted.transport(),
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
    };
    const messages = oneUserMessage("hi");
    var resp = try p.chat(std.testing.allocator, .{ .model = "claude-sonnet-5", .messages = &messages });
    defer resp.deinit();

    try std.testing.expectEqual(.end_turn, resp.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expectEqualStrings("hello there", resp.content[0].text);
}

// Scenario: Given a response with a tool_use content block, when parsed,
// then ChatResponse holds the tool id/name and stop_reason tool_use.
test "parses a tool_use response" {
    const scripted = ScriptedTransport{
        .status = 200,
        .body =
        \\{"content":[{"type":"tool_use","id":"call_1","name":"file_read","input":{"path":"a.zig"}}],"stop_reason":"tool_use"}
        ,
    };
    const p = anthropic.AnthropicProvider{
        .transport = scripted.transport(),
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
    };
    const messages = oneUserMessage("read a.zig");
    var resp = try p.chat(std.testing.allocator, .{ .model = "claude-sonnet-5", .messages = &messages });
    defer resp.deinit();

    try std.testing.expectEqual(.tool_use, resp.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expectEqualStrings("call_1", resp.content[0].tool_use.id);
    try std.testing.expectEqualStrings("file_read", resp.content[0].tool_use.name);
    try std.testing.expectEqualStrings("a.zig", resp.content[0].tool_use.input.object.get("path").?.string);
}

// Scenario: Given a non-200 status, when chat() is called, then it returns
// an error rather than trying to parse an error body as a chat response.
test "non-200 status surfaces as an error" {
    const scripted = ScriptedTransport{ .status = 401, .body = "{\"error\":\"unauthorized\"}" };
    const p = anthropic.AnthropicProvider{
        .transport = scripted.transport(),
        .base_url = "https://api.anthropic.com",
        .api_key = "bad-key",
    };
    const messages = oneUserMessage("hi");
    const result = p.chat(std.testing.allocator, .{ .model = "claude-sonnet-5", .messages = &messages });
    try std.testing.expectError(error.ApiError, result);
}
