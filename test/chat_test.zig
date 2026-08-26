//! BDD spec for src/cli/chat.zig's pure input-classification logic. The
//! `execute()` REPL seam (real stdin/stdout/network) is deliberately
//! untested here — same pattern as cli/run.zig's execute and the plan's
//! manual smoke test.
const std = @import("std");
const opennull = @import("opennull");
const chat = opennull.cli.chat;
const run = opennull.cli.run;

// Scenario: Given an empty line, when parsed, then it is `skip` (no API
// call is made for a bare Enter).
test "parseLine classifies an empty line as skip" {
    try std.testing.expectEqual(chat.ParsedLine.skip, chat.parseLine(""));
}

// Scenario: Given a whitespace-only line, when parsed, then it is also
// `skip`.
test "parseLine classifies a whitespace-only line as skip" {
    try std.testing.expectEqual(chat.ParsedLine.skip, chat.parseLine("   \t  "));
}

// Scenario: Given "/exit", when parsed, then it is the explicit `exit`
// command.
test "parseLine recognizes /exit" {
    try std.testing.expectEqual(chat.ParsedLine.exit, chat.parseLine("/exit"));
}

// Scenario: Given "/quit", when parsed, then it is likewise `exit`.
test "parseLine recognizes /quit as an alias of /exit" {
    try std.testing.expectEqual(chat.ParsedLine.exit, chat.parseLine("/quit"));
}

// Scenario: Given ordinary text, when parsed, then it becomes a `prompt`
// carrying the trimmed text.
test "parseLine wraps ordinary text as a trimmed prompt" {
    const parsed = chat.parseLine("  fix the bug in main.zig  ");
    try std.testing.expectEqualStrings("fix the bug in main.zig", parsed.prompt);
}

// Scenario: Given a line ending in \r (CRLF input on Windows-style
// terminals), when parsed, then the carriage return does not leak into
// the prompt text nor defeat /exit detection.
test "parseLine strips trailing carriage returns" {
    try std.testing.expectEqualStrings("hello", chat.parseLine("hello\r").prompt);
    try std.testing.expectEqual(chat.ParsedLine.exit, chat.parseLine("/exit\r"));
}

// -- top-level arg dispatch (lives in cli/run.zig's parseArgs) ----------

// Scenario: Given exactly ["chat"], when parsed, then the command is
// `.chat` and no prompt argument is required.
test "parseArgs recognizes the chat subcommand" {
    const args = [_][]const u8{"chat"};
    try std.testing.expectEqual(run.ParsedArgs.chat, run.parseArgs(&args));
}

// Scenario: Given ["chat"] with extra positional arguments, when parsed,
// then it is rejected as unknown rather than silently ignored.
test "parseArgs rejects extra arguments after chat" {
    const args = [_][]const u8{ "chat", "--flaggy" };
    try std.testing.expectEqual(run.ParsedArgs.unknown, run.parseArgs(&args));
}

// -- tool-activity formatting -------------------------------------------

fn parseJsonValue(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

// Scenario: Given a tool name and its parsed input object, when formatted
// for the REPL, then the line reads "[tool] <name> <compact-json>".
test "formatToolStarted renders the tool name with its compact JSON input" {
    const parsed = try parseJsonValue(std.testing.allocator, "{\"path\":\"greeting.txt\",\"start\":1}");
    defer parsed.deinit();

    const line = try chat.formatToolStarted(std.testing.allocator, "file_read", parsed.value);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("[tool] file_read {\"path\":\"greeting.txt\",\"start\":1}", line);
}

// Scenario: Given an empty input object, when formatted, then the JSON is
// rendered as `{}` rather than omitted.
test "formatToolStarted renders an empty input as {}" {
    const parsed = try parseJsonValue(std.testing.allocator, "{}");
    defer parsed.deinit();

    const line = try chat.formatToolStarted(std.testing.allocator, "does_not_exist", parsed.value);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("[tool] does_not_exist {}", line);
}

// Scenario: Given a successful tool execution, when formatted, then the
// finished line carries no detail — successful file contents are never
// dumped into the transcript.
test "formatToolFinished renders ok without detail on success" {
    const line = try chat.formatToolFinished(std.testing.allocator, "file_read", true, "whole file body\nmore");
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("[tool] file_read ok", line);
}

// Scenario: Given a failed tool execution whose detail spans lines, when
// formatted, then only the FIRST line of the detail appears on the failure
// line so one tool cannot flood the REPL.
test "formatToolFinished renders only the first detail line on failure" {
    const line = try chat.formatToolFinished(std.testing.allocator, "file_edit", false, "old_string not found\nsecond line\nthird");
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("[tool] file_edit failed: old_string not found", line);
}

// -- token/cost line formatting -----------------------------------------

// Scenario: Given turn deltas and session totals, when formatted, then the
// line shows both, with no cost section when pricing is unavailable.
test "formatTokensLine renders turn and session totals without cost" {
    const totals: opennull.agent.usage.UsageTotals = .{
        .requests = 3,
        .input_tokens = 4567,
        .output_tokens = 890,
    };
    const line = try chat.formatTokensLine(std.testing.allocator, 1234, 567, totals, null);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "tokens> 1234 in / 567 out this turn | session 4567 in / 890 out",
        line,
    );
}

// Scenario: Given a computed session cost, when formatted, then it is
// appended as a dollar amount with 4-decimal precision.
test "formatTokensLine appends the cost when priced" {
    const totals: opennull.agent.usage.UsageTotals = .{
        .requests = 1,
        .input_tokens = 100,
        .output_tokens = 50,
    };
    const line = try chat.formatTokensLine(std.testing.allocator, 100, 50, totals, 0.0125);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "tokens> 100 in / 50 out this turn | session 100 in / 50 out | $0.0125",
        line,
    );
}
