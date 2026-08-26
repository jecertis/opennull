//! BDD spec for src/cli/bootstrap.zig's pure error-message mapping. The
//! `bootstrap()` startup seam itself (real .env/config.toml file reads,
//! env resolution, provider construction) is deliberately untested here and
//! exercised end-to-end by the manual smoke test against a local mock
//! server.
const std = @import("std");
const opennull = @import("opennull");
const bootstrap = opennull.cli.bootstrap;

// Scenario: Given a missing config.toml, when mapped, then the message
// tells the user what file is absent and where it was looked for.
test "missing config.toml maps to a message naming the file" {
    const msg = bootstrap.errorMessage(error.FileNotFound);
    try std.testing.expect(std.mem.indexOf(u8, msg, "config.toml") != null);
}

// Scenario: Given an unresolvable api key reference, when mapped, then the
// message mentions both resolution sources (env and .env).
test "missing api key maps to a message covering both lookup sources" {
    const msg = bootstrap.errorMessage(error.MissingApiKeyEnv);
    try std.testing.expect(std.mem.indexOf(u8, msg, ".env") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "api_key_env") != null);
}

// Scenario: Given an unknown default hint, when mapped, then the message
// points at general.default_hint as the culprit.
test "unknown hint maps to a message naming default_hint" {
    const msg = bootstrap.errorMessage(error.UnknownHint);
    try std.testing.expect(std.mem.indexOf(u8, msg, "default_hint") != null);
}

// Scenario: Given any unexpected error tag, when mapped, then a generic
// but non-empty message comes back — no unreachable, no empty string.
test "unexpected errors fall back to a generic message" {
    const msg = bootstrap.errorMessage(error.ConnectionRefused);
    try std.testing.expect(msg.len > 0);
}

// Scenario: Given no config override, when the system prompt is built, then
// it embeds the workspace root and names every registry tool so the model
// knows what it can actually do.
test "default charter embeds workspace root and tool names" {
    const prompt = try bootstrap.buildSystemPrompt(std.testing.allocator, "/work/ws", null);
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "/work/ws") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "file_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "file_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "file_edit") != null);
}

// Scenario: Given an explicit config override, when built, then it is used
// verbatim — no default text appended, no workspace root injected.
test "config override replaces the default charter verbatim" {
    const prompt = try bootstrap.buildSystemPrompt(std.testing.allocator, "/work/ws", "be terse");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("be terse", prompt);
}
