//! BDD spec for src/cli/run.zig's pure argument-parsing and output-
//! formatting logic. The actual `execute()` orchestration (reads a real
//! env var, opens a real HTTP connection) is a thin, deliberately
//! untestable seam exercised by the plan's manual smoke test instead —
//! same pattern as provider/http.zig's `send`.
const std = @import("std");
const opennull = @import("opennull");
const run = opennull.cli.run;
const provider = opennull.provider.core;

// Scenario: Given `run "<prompt>"` args, when parsed, then the prompt text
// is extracted.
test "parseArgs extracts the prompt from a run command" {
    const args = [_][]const u8{ "run", "fix the bug in main.zig" };
    const parsed = run.parseArgs(&args);
    try std.testing.expectEqualStrings("fix the bug in main.zig", parsed.run.prompt);
}

// Scenario: Given `run` with no prompt argument, when parsed, then the
// result is `missing_prompt`, not a crash or an empty-string prompt.
test "parseArgs reports missing_prompt when no prompt is given" {
    const args = [_][]const u8{"run"};
    const parsed = run.parseArgs(&args);
    try std.testing.expectEqual(run.ParsedArgs.missing_prompt, parsed);
}

// Scenario: Given an unrecognized subcommand, when parsed, then the result
// is `unknown`.
test "parseArgs reports unknown for an unrecognized subcommand" {
    const args = [_][]const u8{"frobnicate"};
    const parsed = run.parseArgs(&args);
    try std.testing.expectEqual(run.ParsedArgs.unknown, parsed);
}

// Scenario: Given no arguments at all, when parsed, then the result is
// `unknown` (main.zig is responsible for printing usage in that case).
test "parseArgs reports unknown for no arguments" {
    const parsed = run.parseArgs(&.{});
    try std.testing.expectEqual(run.ParsedArgs.unknown, parsed);
}

// Scenario: Given a ChatResponse with only a text block, when the reply
// text is extracted, then it returns exactly that text.
test "extractText returns the text of a single text block" {
    const content = [_]provider.ContentBlock{.{ .text = "hello there" }};
    const response = provider.ChatResponse{ .content = &content, .stop_reason = .end_turn };
    const text = try run.extractText(std.testing.allocator, response);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello there", text);
}

// Scenario: Given a ChatResponse mixing text and tool_use blocks, when the
// reply text is extracted, then only the text blocks are concatenated and
// the tool_use block is skipped.
test "extractText concatenates text blocks and skips tool_use blocks" {
    const content = [_]provider.ContentBlock{
        .{ .text = "part one " },
        .{ .tool_use = .{ .id = "x", .name = "file_read", .input = .null } },
        .{ .text = "part two" },
    };
    const response = provider.ChatResponse{ .content = &content, .stop_reason = .tool_use };
    const text = try run.extractText(std.testing.allocator, response);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("part one part two", text);
}

// Scenario: Given a ChatResponse with no content blocks at all, when the
// reply text is extracted, then it returns an empty (but valid) string.
test "extractText returns empty string for no content blocks" {
    const response = provider.ChatResponse{ .content = &.{}, .stop_reason = .end_turn };
    const text = try run.extractText(std.testing.allocator, response);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}
