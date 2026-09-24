//! `opennull run "<prompt>"` — a one-shot AGENT turn: the prompt goes
//! through the same session machinery as `chat` (tool registry, sandbox,
//! token accounting), just without follow-up turns. `parseArgs` and
//! `extractText` are pure and fully unit-tested (test/run_test.zig);
//! `execute` is the thin, deliberately untestable seam doing real I/O.
const std = @import("std");
const provider = @import("../provider/provider.zig");
const sandbox = @import("../security/sandbox.zig");
const session = @import("../agent/session.zig");
const usage_mod = @import("../agent/usage.zig");
const bootstrap = @import("bootstrap.zig");
const display = @import("display.zig");
const approval = @import("approval.zig");
const route_events = @import("route_events.zig");
const router = @import("../router/router.zig");

pub const ParsedArgs = union(enum) {
    run: struct { prompt: []const u8 },
    chat,
    missing_prompt,
    unknown,
};

/// `args` excludes the program name, e.g. `["run", "fix the bug"]`.
pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len == 0) return .chat;
    if (std.mem.eql(u8, args[0], "chat")) {
        if (args.len > 1) return .unknown;
        return .chat;
    }
    if (!std.mem.eql(u8, args[0], "run")) return .unknown;
    if (args.len < 2 or args[1].len == 0) return .missing_prompt;
    return .{ .run = .{ .prompt = args[1] } };
}

/// Reply-text extraction moved to provider.extractText so the chat session
/// and future TUI share one implementation.
pub const extractText = provider.extractText;

/// Boots the router-driven path (config.toml + .env + default hint) and
/// runs ONE full agent turn — tools included — printing tool activity as
/// it happens and a token/cost line afterwards. No follow-up turns: the
/// process exits after the first non-tool answer.
pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    prompt: []const u8,
    stdout: *std.Io.Writer,
) !void {
    var boot = bootstrap.bootstrap(allocator, io, environ_map) catch |err| {
        try stdout.print("error: {s} ({t})\n", .{ bootstrap.errorMessage(err), err });
        return;
    };
    defer boot.deinit();

    const policy = sandbox.SecurityPolicy{
        .workspace_root = boot.workspace_root,
        .allow = boot.config.sandbox_allow,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var history: session.History = .empty;
    var totals: usage_mod.UsageTotals = .{};
    var activity_reporter = display.StdoutReporter{ .allocator = allocator, .w = stdout };
    var live = display.LiveTextPrinter{ .w = stdout, .prefix = "" };
    var stdin_buffer: [256]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    var session_approver = approval.SessionApprover{ .console = .{ .reader = &stdin_file_reader.interface, .w = stdout } };
    defer session_approver.deinit();
    if (boot.config.telemetry.local_events) {
        try session_approver.enableEventLog(allocator, io, boot.workspace_root, boot.config.telemetry.record_text);
    }
    var recorder = route_events.RouteRecorder{ .log = session_approver.eventLog() };
    if (try bootstrap.routerStatus(&boot, allocator)) |status| {
        defer allocator.free(status);
        try stdout.print("{s}\n", .{status});
    }
    const choice = bootstrap.classify(&boot, prompt);
    const selected = bootstrap.routeForHint(&boot, choice.hint);
    recorder.decided(prompt, choice, selected.model);
    const prov = try bootstrap.providerFor(&boot, selected);
    try stdout.print("route> {s}\n", .{selected.model});

    const reply = session.sendPrompt(
        arena.allocator(),
        io,
        prov,
        &policy,
        &history,
        selected.model,
        prompt,
        .{
            .reporter = activity_reporter.reporter(),
            .totals = &totals,
            .system = boot.system_prompt,
            .text_sink = live.sink(),
            .approver = session_approver.approver(),
        },
    ) catch |err| {
        try stdout.print("error: request failed: {t}\n", .{err});
        return;
    };
    if (live.printed_any) {
        try stdout.print("\n", .{});
    } else {
        try stdout.print("{s}\n", .{reply});
    }
    recorder.turnFinished(choice.hint, session_approver.console.approved_count);

    const line = try display.formatTokensLine(
        allocator,
        totals.input_tokens,
        totals.output_tokens,
        totals,
        usage_mod.costOf(boot.config.pricing, selected.model, totals),
    );
    defer allocator.free(line);
    try stdout.print("{s}\n", .{line});
}
