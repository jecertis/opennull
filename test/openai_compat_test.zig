//! BDD spec for src/provider/openai_compat.zig — proves the neutral
//! ChatRequest/ChatResponse abstraction really is provider-neutral by
//! implementing a second, differently-shaped wire format (OpenAI's
//! chat/completions) against the same injectable Transport pattern used
//! by anthropic_test.zig.
const std = @import("std");
const opennull = @import("opennull");
const provider = opennull.provider.core;
const openai = opennull.provider.openai_compat;

const CapturingTransport = struct {
    fn send(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.HttpResponse {
        _ = ptr;
        try std.testing.expect(std.mem.endsWith(u8, req.url, "/chat/completions"));

        var has_auth = false;
        for (req.headers) |h| {
            if (std.mem.eql(u8, h.name, "authorization") and std.mem.eql(u8, h.value, "Bearer test-key")) has_auth = true;
        }
        try std.testing.expect(has_auth);
        try std.testing.expect(std.mem.indexOf(u8, req.body, "gpt-test-model") != null);
        try std.testing.expect(std.mem.indexOf(u8, req.body, "\"role\":\"user\"") != null);

        const body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi from fake\"},\"finish_reason\":\"stop\"}]}";
        return .{ .status = 200, .body = try allocator.dupe(u8, body) };
    }

    fn transport() provider.Transport {
        return .{ .ptr = undefined, .sendFn = send };
    }
};

fn oneUserMessage(text: []const u8) [1]provider.Message {
    return .{.{ .role = .user, .content = &.{.{ .text = text }} }};
}

test "sends request to chat/completions with bearer auth and body shape" {
    const p = openai.OpenAiCompatProvider{
        .transport = CapturingTransport.transport(),
        .base_url = "https://api.openai.example",
        .api_key = "test-key",
    };
    const messages = oneUserMessage("hello");
    var resp = try p.chat(std.testing.allocator, .{ .model = "gpt-test-model", .messages = &messages });
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

// Scenario: Given a choices[0].message.content text response with
// finish_reason "stop", when parsed, then ChatResponse holds that text and
// stop_reason end_turn.
test "parses a text-only response" {
    const scripted = ScriptedTransport{
        .status = 200,
        .body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello there\"},\"finish_reason\":\"stop\"}]}",
    };
    const p = openai.OpenAiCompatProvider{ .transport = scripted.transport(), .base_url = "https://api.openai.example", .api_key = "k" };
    const messages = oneUserMessage("hi");
    var resp = try p.chat(std.testing.allocator, .{ .model = "gpt-test-model", .messages = &messages });
    defer resp.deinit();

    try std.testing.expectEqual(.end_turn, resp.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expectEqualStrings("hello there", resp.content[0].text);
}

// Scenario: Given a tool_calls response with finish_reason "tool_calls",
// when parsed, then ChatResponse holds the call's id/name and its
// JSON-string `arguments` decoded into a structured input value, with
// stop_reason tool_use.
test "parses a tool_calls response" {
    const scripted = ScriptedTransport{
        .status = 200,
        .body =
        \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"file_read","arguments":"{\"path\":\"a.zig\"}"}}]},"finish_reason":"tool_calls"}]}
        ,
    };
    const p = openai.OpenAiCompatProvider{ .transport = scripted.transport(), .base_url = "https://api.openai.example", .api_key = "k" };
    const messages = oneUserMessage("read a.zig");
    var resp = try p.chat(std.testing.allocator, .{ .model = "gpt-test-model", .messages = &messages });
    defer resp.deinit();

    try std.testing.expectEqual(.tool_use, resp.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expectEqualStrings("call_1", resp.content[0].tool_use.id);
    try std.testing.expectEqualStrings("file_read", resp.content[0].tool_use.name);
    try std.testing.expectEqualStrings("a.zig", resp.content[0].tool_use.input.object.get("path").?.string);
}

test "non-200 status surfaces as an error" {
    const scripted = ScriptedTransport{ .status = 401, .body = "{\"error\":\"unauthorized\"}" };
    const p = openai.OpenAiCompatProvider{ .transport = scripted.transport(), .base_url = "https://api.openai.example", .api_key = "bad" };
    const messages = oneUserMessage("hi");
    const result = p.chat(std.testing.allocator, .{ .model = "gpt-test-model", .messages = &messages });
    try std.testing.expectError(error.ApiError, result);
}
