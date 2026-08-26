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

pub const ParsedArgs = union(enum) {
    run: struct { prompt: []const u8 },
    chat,
    missing_prompt,
    unknown,
};

/// `args` excludes the program name, e.g. `["run", "fix the bug"]`.
pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len == 0) return .unknown;
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

    const reply = session.sendPrompt(
        arena.allocator(),
        io,
        boot.provider,
        &policy,
        &history,
        boot.model,
        prompt,
        activity_reporter.reporter(),
        &totals,
    ) catch |err| {
        try stdout.print("error: request failed: {t}\n", .{err});
        return;
    };
    try stdout.print("{s}\n", .{reply});

    const line = try display.formatTokensLine(
        allocator,
        totals.input_tokens,
        totals.output_tokens,
        totals,
        usage_mod.costOf(boot.config.pricing, boot.model, totals),
    );
    defer allocator.free(line);
    try stdout.print("{s}\n", .{line});
}
