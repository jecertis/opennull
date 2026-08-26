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

pub const ParsedLine = union(enum) {
    /// Empty or whitespace-only input: ignore without an API call.
    skip,
    /// Explicit quit command.
    exit,
    /// Any other non-empty line is a user prompt (trimmed).
    prompt: []const u8,
};

/// Classifies one raw line read from stdin (no trailing newline).
pub fn parseLine(raw: []const u8) ParsedLine {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0) return .skip;
    if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return .exit;
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
            "type a prompt, /exit to quit\n",
        .{policy.workspace_root},
    );

    var stdin_buffer: [16384]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    while (true) {
        try stdout.print("you> ", .{});
        try stdout.flush();

        // null only on clean EOF before any bytes (Ctrl-D) — our exit.
        const raw_line = stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stdout.print("error: line exceeds {d}-byte input buffer; exiting\n", .{stdin_buffer.len});
                break;
            },
            else => return err,
        } orelse break;

        switch (parseLine(raw_line)) {
            .skip => continue,
            .exit => break,
            .prompt => |text| {
                const in_before = totals.input_tokens;
                const out_before = totals.output_tokens;
                var live = display.LiveTextPrinter{ .w = stdout, .prefix = "assistant> " };
                const reply = session.sendPrompt(
                    arena.allocator(),
                    io,
                    boot.provider,
                    &policy,
                    &history,
                    boot.model,
                    text,
                    .{
                        .reporter = activity_reporter.reporter(),
                        .totals = &totals,
                        .system = boot.system_prompt,
                        .text_sink = live.sink(),
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
                const line = try display.formatTokensLine(
                    allocator,
                    totals.input_tokens - in_before,
                    totals.output_tokens - out_before,
                    totals,
                    usage_mod.costOf(boot.config.pricing, boot.model, totals),
                );
                defer allocator.free(line);
                try stdout.print("{s}\n", .{line});
            },
        }
    }
}
