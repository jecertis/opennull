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
