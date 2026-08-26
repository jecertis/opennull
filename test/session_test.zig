//! BDD spec for src/agent/session.zig — multi-turn conversation state.
//! Uses a capturing sequenced fake Transport (no real network or model)
//! so the history-accumulation logic is tested deterministically: each
//! request body is recorded verbatim before a canned response is fed back.
const std = @import("std");
const opennull = @import("opennull");
const provider = opennull.provider.core;
const anthropic = opennull.provider.anthropic;
const sandbox = opennull.security;
const session = opennull.agent.session;
const loop = opennull.agent.loop;

fn workspaceRootOf(dir: std.Io.Dir, buf: []u8) []const u8 {
    const len = dir.realPath(std.testing.io, buf) catch @panic("realPath failed in test setup");
    return buf[0..len];
}

/// Records every ToolActivity the session forwards, in order.
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

const ScriptedResponse = struct { status: u16, body: []const u8 };

/// Records every request body it is handed (owned copy), then returns the
/// next scripted response.
const CapturingTransport = struct {
    responses: []const ScriptedResponse,
    call_index: usize = 0,
    request_bodies: std.ArrayListUnmanaged([]const u8) = .empty,

    fn send(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.HttpResponse {
        const self: *CapturingTransport = @ptrCast(@alignCast(ptr));
        try self.request_bodies.append(allocator, try allocator.dupe(u8, req.body));
        const idx = @min(self.call_index, self.responses.len - 1);
        const r = self.responses[idx];
        self.call_index += 1;
        return .{ .status = r.status, .body = try allocator.dupe(u8, r.body) };
    }

    fn transport(self: *CapturingTransport) provider.Transport {
        return .{ .ptr = self, .sendFn = send };
    }
};

// Scenario: Given a fresh session, when one prompt is sent, then the
// reply text is returned and the history holds exactly [user, assistant].
test "sendPrompt returns the reply and records both sides of the exchange" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var transport = CapturingTransport{ .responses = &.{
        .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"first answer\"}],\"stop_reason\":\"end_turn\"}" },
    } };
    const p = anthropic.AnthropicProvider{ .transport = transport.transport(), .base_url = "https://api.anthropic.com", .api_key = "k" };

    var history: loop.History = .empty;
    const reply = try session.sendPrompt(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", "first question", null);

    try std.testing.expectEqualStrings("first answer", reply);
    try std.testing.expectEqual(@as(usize, 2), history.items.len);
    try std.testing.expectEqual(provider.Role.user, history.items[0].role);
    try std.testing.expectEqualStrings("first question", history.items[0].content[0].text);
    try std.testing.expectEqual(provider.Role.assistant, history.items[1].role);
    try std.testing.expectEqualStrings("first answer", history.items[1].content[0].text);
}

// Scenario: Given an existing exchange in the session, when a second
// prompt is sent, then the outgoing request carries the FULL prior
// conversation — first question, first answer, and the follow-up — so the
// model sees real multi-turn context.
test "a second prompt sends the accumulated conversation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var transport = CapturingTransport{ .responses = &.{
        .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"first answer\"}],\"stop_reason\":\"end_turn\"}" },
        .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"second answer\"}],\"stop_reason\":\"end_turn\"}" },
    } };
    const p = anthropic.AnthropicProvider{ .transport = transport.transport(), .base_url = "https://api.anthropic.com", .api_key = "k" };

    var history: loop.History = .empty;
    _ = try session.sendPrompt(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", "my first question", null);
    _ = try session.sendPrompt(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", "and a follow-up", null);

    try std.testing.expectEqual(@as(usize, 2), transport.request_bodies.items.len);

    // First request contains only the opening prompt.
    const first_body = transport.request_bodies.items[0];
    try std.testing.expect(std.mem.indexOf(u8, first_body, "my first question") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_body, "follow-up") == null);

    // Second request replays the whole exchange plus the new prompt.
    const second_body = transport.request_bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, second_body, "my first question") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_body, "first answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_body, "and a follow-up") != null);

    try std.testing.expectEqual(@as(usize, 4), history.items.len);
}

// Scenario: Given a prompt that lives in transient memory (like a stdin
// reader's buffer), when the caller reuses/overwrites that memory for the
// next line, then the history still holds the original prompt text — i.e.
// sendPrompt deep-copies input instead of aliasing the caller's buffer.
test "prompts are deep-copied so overwriting the source buffer cannot corrupt history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var transport = CapturingTransport{ .responses = &.{
        .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\"}" },
    } };
    const p = anthropic.AnthropicProvider{ .transport = transport.transport(), .base_url = "https://api.anthropic.com", .api_key = "k" };

    var history: loop.History = .empty;

    var line_buffer: [64]u8 = undefined;
    @memcpy(line_buffer[0..13], "original text");
    const prompt = line_buffer[0..13];
    _ = try session.sendPrompt(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", prompt, null);

    // Simulate the reader reusing its buffer for the next line.
    @memset(&line_buffer, 'x');

    try std.testing.expectEqualStrings("original text", history.items[0].content[0].text);
}

// Scenario: Given a reporter is handed to sendPrompt, when a scripted turn
// requests a tool, then the events flow through the session to the
// reporter — the CLI layer can observe activity without touching the loop.
test "sendPrompt forwards tool activity to the caller's reporter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "greeting.txt", .data = "hello from file" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const policy = sandbox.SecurityPolicy{ .workspace_root = workspaceRootOf(tmp.dir, &root_buf) };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var transport = CapturingTransport{ .responses = &.{
        .{ .status = 200, .body =
        \\{"content":[{"type":"tool_use","id":"call_1","name":"file_read","input":{"path":"greeting.txt"}}],"stop_reason":"tool_use"}
        },
        .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"done reading\"}],\"stop_reason\":\"end_turn\"}" },
    } };
    const p = anthropic.AnthropicProvider{ .transport = transport.transport(), .base_url = "https://api.anthropic.com", .api_key = "k" };

    var history: loop.History = .empty;

    var recorder = RecordingReporter{};
    defer recorder.events.deinit(std.testing.allocator);
    _ = try session.sendPrompt(a, std.testing.io, p, &policy, &history, "claude-sonnet-5", "read greeting.txt", recorder.reporter());

    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("file_read", recorder.events.items[0].started.name);
    try std.testing.expect(recorder.events.items[1].finished.ok);
}
