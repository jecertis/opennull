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

    const final = try loop.runTurn(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", .{});

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

    const final = try loop.runTurn(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", .{});

    try std.testing.expectEqual(.end_turn, final.stop_reason);
    try std.testing.expect(history.items[2].content[0].tool_result.is_error);
}

/// Collects every ToolActivity the loop emits, in order. Recorded slices
/// alias the provider's parsed-JSON arena, which lives as long as the test.
const RecordingReporter = struct {
    events: std.ArrayListUnmanaged(loop.ToolActivity) = .empty,

    fn reporter(self: *RecordingReporter) loop.Reporter {
        return .{ .ptr = self, .notifyFn = notify };
    }

    fn notify(ptr: *anyopaque, activity: loop.ToolActivity) void {
        const self: *RecordingReporter = @ptrCast(@alignCast(ptr));
        self.events.append(std.testing.allocator, activity) catch @panic("OOM recording tool activity");
    }
};

// Scenario: Given a scripted turn that requests file_read and then answers,
// when a recording reporter is attached, then it observes exactly one
// `started` event carrying the tool's parsed input, followed by one
// `finished` event marked ok with the tool's real output as detail.
test "reports started and finished events around a successful tool call" {
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

    var recorder = RecordingReporter{};
    defer recorder.events.deinit(std.testing.allocator);
    _ = try loop.runTurn(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", .{ .reporter = recorder.reporter() });

    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);

    const started = recorder.events.items[0].started;
    try std.testing.expectEqualStrings("file_read", started.name);
    try std.testing.expectEqualStrings("greeting.txt", started.input.object.get("path").?.string);

    const finished = recorder.events.items[1].finished;
    try std.testing.expectEqualStrings("file_read", finished.name);
    try std.testing.expect(finished.ok);
    try std.testing.expectEqualStrings("hello from file", finished.detail);
}

// Scenario: Given a scripted tool_use naming an unregistered tool, when the
// loop runs with a reporter attached, then the failure is still reported —
// finished(ok=false) with the loop's own "unknown tool" detail — so UIs can
// surface the failed attempt instead of silence.
test "a failed unknown-tool dispatch emits a not-ok finished event" {
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

    var recorder = RecordingReporter{};
    defer recorder.events.deinit(std.testing.allocator);
    _ = try loop.runTurn(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", .{ .reporter = recorder.reporter() });

    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("does_not_exist", recorder.events.items[0].started.name);

    const finished = recorder.events.items[1].finished;
    try std.testing.expect(!finished.ok);
    try std.testing.expectEqualStrings("unknown tool", finished.detail);
}

// Scenario: Given a tool-using turn (two API requests: tool_use then
// end_turn) where each response carries usage, when the loop runs with a
// totals accumulator, then EVERY request's tokens are counted — not just
// the final one.
test "totals accumulate across every request in a multi-request turn" {
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
        \\{"content":[{"type":"tool_use","id":"call_1","name":"file_read","input":{"path":"greeting.txt"}}],"stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":10}}
        },
        .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"done reading\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":250,\"output_tokens\":15}}" },
    } };
    const p = anthropic.AnthropicProvider{ .transport = transport.transport(), .base_url = "https://api.anthropic.com", .api_key = "k" };

    var history = try oneUserMessage(a, "read greeting.txt");

    var totals: opennull.agent.usage.UsageTotals = .{};
    _ = try loop.runTurn(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", .{ .totals = &totals });

    try std.testing.expectEqual(@as(u32, 2), totals.requests);
    try std.testing.expectEqual(@as(u64, 350), totals.input_tokens);
    try std.testing.expectEqual(@as(u64, 25), totals.output_tokens);
}
