//! BDD spec for src/agent/loop.zig — the actual turn loop tying provider,
//! tool registry, and sandbox together. Uses a scripted/sequenced fake
//! Transport (no real network or model) so the tool-dispatch logic is
//! tested deterministically: it feeds a canned tool_use response first,
//! then a canned end_turn response, and asserts the loop actually executed
//! the real tool (against a real temp file) and fed its result back before
//! producing the final answer.
const std = @import("std");
const opennull = @import("opennull");
const provider = opennull.provider.core;
const anthropic = opennull.provider.anthropic;
const sandbox = opennull.security;
const loop = opennull.agent.loop;

fn workspaceRootOf(dir: std.Io.Dir, buf: []u8) []const u8 {
    const len = dir.realPath(std.testing.io, buf) catch @panic("realPath failed in test setup");
    return buf[0..len];
}

const ScriptedResponse = struct { status: u16, body: []const u8 };

const SequencedTransport = struct {
    responses: []const ScriptedResponse,
    call_index: usize = 0,

    fn send(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.HttpResponse {
        _ = req;
        const self: *SequencedTransport = @ptrCast(@alignCast(ptr));
        const idx = @min(self.call_index, self.responses.len - 1);
        const r = self.responses[idx];
        self.call_index += 1;
        return .{ .status = r.status, .body = try allocator.dupe(u8, r.body) };
    }

    fn transport(self: *SequencedTransport) provider.Transport {
        return .{ .ptr = self, .sendFn = send };
    }
};

fn oneUserMessage(allocator: std.mem.Allocator, text: []const u8) !loop.History {
    var history: loop.History = .empty;
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(provider.ContentBlock, &.{.{ .text = text }}) });
    return history;
}

// Scenario: Given a scripted turn that first requests file_read and then
// answers with text, when the loop runs, then it actually executes
// file_read against the real sandboxed file, feeds the real content back,
// and returns the final text answer.
test "executes a requested tool and continues to the final answer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "greeting.txt", .data = "hello from file" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var transport = SequencedTransport{ .responses = &.{
        .{ .status = 200, .body =
        \\{"content":[{"type":"tool_use","id":"call_1","name":"file_read","input":{"path":"greeting.txt"}}],"stop_reason":"tool_use"}
        },
        .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"done reading\"}],\"stop_reason\":\"end_turn\"}" },
    } };
    const p = anthropic.AnthropicProvider{ .transport = transport.transport(), .base_url = "https://api.anthropic.com", .api_key = "k" };

    var history = try oneUserMessage(a, "read greeting.txt");

    const final = try loop.runTurn(a, std.testing.io, p, &policy, &history, "claude-sonnet-5");

    try std.testing.expectEqual(.end_turn, final.stop_reason);
    try std.testing.expectEqualStrings("done reading", final.content[0].text);

    // history: user, assistant(tool_use), tool(tool_result), assistant(final text)
    try std.testing.expectEqual(@as(usize, 4), history.items.len);
    try std.testing.expectEqual(provider.Role.tool, history.items[2].role);
    try std.testing.expectEqualStrings("hello from file", history.items[2].content[0].tool_result.content);
    try std.testing.expect(!history.items[2].content[0].tool_result.is_error);
}

// Scenario: Given a scripted tool_use response naming a tool that doesn't
// exist in the registry, when the loop runs, then it does not crash — it
// records a failed tool_result and continues to the next turn.
test "an unknown tool name produces a failed tool_result instead of crashing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var transport = SequencedTransport{ .responses = &.{
        .{ .status = 200, .body =
        \\{"content":[{"type":"tool_use","id":"call_1","name":"does_not_exist","input":{}}],"stop_reason":"tool_use"}
        },
        .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"handled\"}],\"stop_reason\":\"end_turn\"}" },
    } };
    const p = anthropic.AnthropicProvider{ .transport = transport.transport(), .base_url = "https://api.anthropic.com", .api_key = "k" };

    var history = try oneUserMessage(a, "do something unsupported");

    const final = try loop.runTurn(a, std.testing.io, p, &policy, &history, "claude-sonnet-5");

    try std.testing.expectEqual(.end_turn, final.stop_reason);
    try std.testing.expect(history.items[2].content[0].tool_result.is_error);
}
