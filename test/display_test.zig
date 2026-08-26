//! BDD spec for src/cli/display.zig — pure presentation formatters shared
//! by the run and chat commands (tool activity lines, token/cost line).
//! The StdoutReporter's I/O behavior is exercised end-to-end by the manual
//! smoke tests against a local mock server.
const std = @import("std");
const opennull = @import("opennull");
const display = opennull.cli.display;



fn parseJsonValue(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

// Scenario: Given a tool name and its parsed input object, when formatted
// for the REPL, then the line reads "[tool] <name> <compact-json>".
test "formatToolStarted renders the tool name with its compact JSON input" {
    const parsed = try parseJsonValue(std.testing.allocator, "{\"path\":\"greeting.txt\",\"start\":1}");
    defer parsed.deinit();

    const line = try display.formatToolStarted(std.testing.allocator, "file_read", parsed.value);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("[tool] file_read {\"path\":\"greeting.txt\",\"start\":1}", line);
}

// Scenario: Given an empty input object, when formatted, then the JSON is
// rendered as `{}` rather than omitted.
test "formatToolStarted renders an empty input as {}" {
    const parsed = try parseJsonValue(std.testing.allocator, "{}");
    defer parsed.deinit();

    const line = try display.formatToolStarted(std.testing.allocator, "does_not_exist", parsed.value);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("[tool] does_not_exist {}", line);
}

// Scenario: Given a successful tool execution, when formatted, then the
// finished line carries no detail — successful file contents are never
// dumped into the transcript.
test "formatToolFinished renders ok without detail on success" {
    const line = try display.formatToolFinished(std.testing.allocator, "file_read", true, "whole file body\nmore");
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("[tool] file_read ok", line);
}

// Scenario: Given a failed tool execution whose detail spans lines, when
// formatted, then only the FIRST line of the detail appears on the failure
// line so one tool cannot flood the REPL.
test "formatToolFinished renders only the first detail line on failure" {
    const line = try display.formatToolFinished(std.testing.allocator, "file_edit", false, "old_string not found\nsecond line\nthird");
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
    const line = try display.formatTokensLine(std.testing.allocator, 1234, 567, totals, null);
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
    const line = try display.formatTokensLine(std.testing.allocator, 100, 50, totals, 0.0125);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "tokens> 100 in / 50 out this turn | session 100 in / 50 out | $0.0125",
        line,
    );
}
