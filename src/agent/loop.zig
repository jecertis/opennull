//! The agent turn loop: sends history + tool specs to a provider, executes
//! any requested tools through the sandboxed registry, feeds results back,
//! and repeats until a non-tool_use stop reason. See test/loop_test.zig.
const std = @import("std");
const provider = @import("../provider/provider.zig");
const registry = @import("../tools/registry.zig");
const sandbox = @import("../security/sandbox.zig");
const usage_mod = @import("usage.zig");
const tool_policy = @import("tool_policy.zig");

pub const History = std.ArrayListUnmanaged(provider.Message);

/// One observation about a tool execution inside the turn loop, emitted to
/// the optional Reporter so UIs (REPL, future TUI) can show live activity.
pub const ToolActivity = union(enum) {
    started: struct { name: []const u8, input: std.json.Value },
    approval_requested: struct { name: []const u8, input: std.json.Value },
    finished: struct { name: []const u8, ok: bool, detail: []const u8 },
};

/// A UI-owned confirmation hook for a single mutating tool call. Returning
/// false (including because input is unavailable) declines the operation.
pub const Approver = struct {
    ptr: *anyopaque,
    approveFn: *const fn (ptr: *anyopaque, name: []const u8, input: std.json.Value) bool,

    pub fn approve(self: Approver, name: []const u8, input: std.json.Value) bool {
        return self.approveFn(self.ptr, name, input);
    }
};

/// Context + function-pointer pair (same vtable style as
/// provider.Transport) — `notify` MUST NOT fail; visibility is best-effort.
pub const Reporter = struct {
    ptr: *anyopaque,
    notifyFn: *const fn (ptr: *anyopaque, activity: ToolActivity) void,

    pub fn notify(self: Reporter, activity: ToolActivity) void {
        self.notifyFn(self.ptr, activity);
    }
};

/// Per-turn options: everything optional the loop needs from its callers.
pub const Options = struct {
    /// Live tool activity (for UIs).
    reporter: ?Reporter = null,
    /// Usage accumulation across every request in the turn.
    totals: ?*usage_mod.UsageTotals = null,
    /// System prompt sent with each request.
    system: ?[]const u8 = null,
    /// When set, the turn streams: live text deltas push here. If the
    /// transport cannot stream, buffered chat is used instead.
    text_sink: ?provider.StreamSink = null,
    /// Required by the built-in policy before file_write/file_edit execute.
    /// Absence is equivalent to declining, which keeps noninteractive callers
    /// safe by default.
    approver: ?Approver = null,
};

/// `allocator` MUST be a bulk-reclaim allocator (an arena) owned by the
/// caller for the whole turn/session: this function does not free any
/// individual allocation (including intermediate or the returned
/// ChatResponse, whose own parsed-JSON arena is chained off `allocator`) —
/// the caller's `arena.deinit()` reclaims everything transitively in one
/// shot. Never call `.deinit()` on the returned ChatResponse yourself.
pub fn runTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    prov: anytype,
    policy: *const sandbox.SecurityPolicy,
    history: *History,
    model: []const u8,
    opts: Options,
) !provider.ChatResponse {
    while (true) {
        const specs = try registry.buildSpecs(allocator);

        const request = provider.ChatRequest{
            .model = model,
            .system = opts.system,
            .messages = history.items,
            .tools = specs,
        };

        // Prefer streaming when a text sink wants live output; silently
        // fall back when this transport can't stream. Server-side failures
        // are real errors and propagate.
        const resp = if (opts.text_sink != null)
            prov.chatStreaming(allocator, request, opts.text_sink.?) catch |err| switch (err) {
                error.NotSupported => try prov.chat(allocator, request),
                else => return err,
            }
        else
            try prov.chat(allocator, request);

        if (resp.usage) |u| {
            if (opts.totals) |t| t.add(u);
        }
        try history.append(allocator, .{ .role = .assistant, .content = resp.content });

        if (resp.stop_reason != .tool_use) {
            return resp;
        }

        var results: std.ArrayListUnmanaged(provider.ContentBlock) = .empty;
        for (resp.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    var result_content: []const u8 = "unknown tool";
                    var is_err = true;

                    if (registry.find(tu.name)) |t| {
                        const approved = blk: {
                            if (tool_policy.decide(tu.name) == .allow) break :blk true;
                            if (opts.reporter) |rep| rep.notify(.{ .approval_requested = .{ .name = tu.name, .input = tu.input } });
                            break :blk if (opts.approver) |a| a.approve(tu.name, tu.input) else false;
                        };
                        if (!approved) {
                            result_content = "user declined tool execution";
                            is_err = true;
                        } else if (t.execute(allocator, io, policy, tu.input)) |result| {
                            if (opts.reporter) |rep| rep.notify(.{ .started = .{ .name = tu.name, .input = tu.input } });
                            if (result.success) {
                                result_content = result.output;
                                is_err = false;
                            } else {
                                result_content = result.err orelse "tool failed";
                                is_err = true;
                            }
                        } else |err| {
                            result_content = @errorName(err);
                            is_err = true;
                        }
                    } else {
                        // Preserve the activity contract for unsupported
                        // requests: the loop attempted dispatch, then
                        // reports its own failure.
                        if (opts.reporter) |rep| rep.notify(.{ .started = .{ .name = tu.name, .input = tu.input } });
                    }

                    if (opts.reporter) |rep| rep.notify(.{ .finished = .{
                        .name = tu.name,
                        .ok = !is_err,
                        .detail = result_content,
                    } });

                    try results.append(allocator, .{ .tool_result = .{
                        .tool_use_id = tu.id,
                        .content = result_content,
                        .is_error = is_err,
                    } });
                },
                else => {},
            }
        }

        try history.append(allocator, .{ .role = .tool, .content = try results.toOwnedSlice(allocator) });
    }
}
