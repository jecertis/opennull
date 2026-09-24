//! `opennull chat` — an interactive multi-turn REPL on top of the agent
//! session. `parseLine` is pure and fully unit-tested (test/chat_test.zig);
//! `execute` is the thin, deliberately untestable seam doing real stdin/
//! stdout/network I/O (provider comes from cli/bootstrap's config.toml-
//! driven path; presentation helpers live in cli/display.zig).
const std = @import("std");
const sandbox = @import("../security/sandbox.zig");
const session = @import("../agent/session.zig");
const usage_mod = @import("../agent/usage.zig");
const bootstrap = @import("bootstrap.zig");
const display = @import("display.zig");
const approval = @import("approval.zig");
const route_events = @import("route_events.zig");
const router = @import("../router/router.zig");

pub const ParsedLine = union(enum) {
    /// Empty or whitespace-only input: ignore without an API call.
    skip,
    /// Explicit quit command.
    exit,
    /// "/fast" or "/powerful": redo the previous prompt on that route.
    override: router.PromptHint,
    /// Any other non-empty line is a user prompt (trimmed).
    prompt: []const u8,
};

/// Classifies one raw line read from stdin (no trailing newline).
pub fn parseLine(raw: []const u8) ParsedLine {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0) return .skip;
    if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return .exit;
    if (std.mem.eql(u8, line, "/fast")) return .{ .override = .fast };
    if (std.mem.eql(u8, line, "/powerful")) return .{ .override = .powerful };
    return .{ .prompt = line };
}

/// Reads lines from stdin until EOF or /exit, running a full agent turn
/// per prompt with the whole-session history retained. One arena backs the
/// entire session and reclaims everything on exit.
pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
) !void {
    var boot = bootstrap.bootstrap(allocator, io, environ_map) catch |err| {
        try stdout.print("error: {s} ({t})\n", .{ bootstrap.errorMessage(err), err });
        return;
    };
    defer boot.deinit();

    // Extra readable paths come straight from config.toml's [sandbox] allow.
    const policy = sandbox.SecurityPolicy{
        .workspace_root = boot.workspace_root,
        .allow = boot.config.sandbox_allow,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var history: session.History = .empty;
    var totals: usage_mod.UsageTotals = .{};

    var activity_reporter = display.StdoutReporter{ .allocator = allocator, .w = stdout };

    try stdout.print(
        "opennull chat — tools enabled, workspace: {s}\n" ++
            "type a prompt, /fast or /powerful to redo the last one on that route, /exit to quit\n",
        .{policy.workspace_root},
    );

    var stdin_buffer: [16384]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;
    var session_approver = approval.SessionApprover{ .console = .{ .reader = stdin, .w = stdout } };
    defer session_approver.deinit();
    if (boot.config.telemetry.local_events) {
        try session_approver.enableEventLog(allocator, io, boot.workspace_root, boot.config.telemetry.record_text);
    }
    var recorder = route_events.RouteRecorder{ .log = session_approver.eventLog() };
    // Copied out of the stdin buffer so /fast and /powerful can resend it.
    var last_prompt: ?[]const u8 = null;

    while (true) {
        try stdout.print("\x1b[32myou>\x1b[0m ", .{});
        try stdout.flush();

        // null only on clean EOF before any bytes (Ctrl-D) — our exit.
        const raw_line = stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stdout.print("error: line exceeds {d}-byte input buffer; exiting\n", .{stdin_buffer.len});
                break;
            },
            else => return err,
        } orelse break;

        // `hint` is the route the turn runs on; `engine_routed` is false when
        // the user forced it, which is not a decision to record.
        const text: []const u8, const hint: router.PromptHint, const engine_routed = switch (parseLine(raw_line)) {
            .skip => continue,
            .exit => break,
            .prompt => |t| blk: {
                const owned = try arena.allocator().dupe(u8, t);
                last_prompt = owned;
                break :blk .{ owned, router.classifyPrompt(owned), true };
            },
            .override => |h| blk: {
                const prev = last_prompt orelse {
                    try stdout.print("nothing to redo yet: type a prompt first\n", .{});
                    continue;
                };
                recorder.overridden(h);
                break :blk .{ prev, h, false };
            },
        };
        const in_before = totals.input_tokens;
        const out_before = totals.output_tokens;
        const approved_before = session_approver.console.approved_count;
        var live = display.LiveTextPrinter{ .w = stdout, .prefix = "assistant> " };
        const selected = bootstrap.routeForHint(&boot, hint);
        if (engine_routed) recorder.decided(text, hint, selected.model);
        const prov = bootstrap.providerFor(&boot, selected) catch |err| {
            try stdout.print("error: route unavailable: {t}\n", .{err});
            continue;
        };
        try stdout.print("route> {s}\n", .{selected.model});
        const reply = session.sendPrompt(
            arena.allocator(),
            io,
            prov,
            &policy,
            &history,
            selected.model,
            text,
            .{
                .reporter = activity_reporter.reporter(),
                .totals = &totals,
                .system = boot.system_prompt,
                .text_sink = live.sink(),
                .approver = session_approver.approver(),
            },
        ) catch |err| {
            // Stay in the session: a failed request must not lose
            // the conversation already accumulated.
            try stdout.print("error: request failed: {t}\n", .{err});
            continue;
        };
        // Streaming already showed the reply live; only the
        // non-streaming fallback needs it printed here.
        if (live.printed_any) {
            try stdout.print("\n", .{});
        } else {
            try stdout.print("assistant> {s}\n", .{reply});
        }
        if (engine_routed) recorder.turnFinished(hint, session_approver.console.approved_count - approved_before);
        const line = try display.formatTokensLine(
            allocator,
            totals.input_tokens - in_before,
            totals.output_tokens - out_before,
            totals,
            usage_mod.costOf(boot.config.pricing, selected.model, totals),
        );
        defer allocator.free(line);
        try stdout.print("{s}\n", .{line});
    }
}
