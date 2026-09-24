//! Deterministic prompt routing for the harness. It is deliberately small,
//! offline, and explainable; a learned classifier can later implement the
//! same `Hint` outcome without changing callers.
const std = @import("std");

pub const Hint = enum { fast, powerful };

const powerful_words = [_][]const u8{
    "implement", "write", "edit",   "modify",    "change",     "fix",    "debug",
    "refactor",  "test",  "design", "architect", "investigat", "analyz", "build",
    "create",
};

/// Returns `powerful` for requests likely to change code or need multi-step
/// reasoning. Direct read-only questions stay on the fast route. Uncertainty
/// intentionally resolves to the more capable route.
pub fn classifyPrompt(prompt: []const u8) Hint {
    var lowered: [4096]u8 = undefined;
    const len = @min(prompt.len, lowered.len);
    for (prompt[0..len], 0..) |c, i| lowered[i] = std.ascii.toLower(c);
    const text = lowered[0..len];
    for (powerful_words) |word| {
        if (startsWord(text, word)) return .powerful;
    }
    for (fast_words) |word| {
        if (startsWord(text, word)) return .fast;
    }
    return .powerful;
}

const fast_words = [_][]const u8{ "read", "show", "list", "find", "explain" };

/// True when `stem` occurs at the start of a word in `text`, so "test"
/// matches "tests" and "testing" but not "latest", and "fix" does not match
/// "prefix". Stems like "investigat" still cover their inflections.
fn startsWord(text: []const u8, stem: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, stem)) |at| {
        if (at == 0 or !std.ascii.isAlphanumeric(text[at - 1])) return true;
        from = at + 1;
    }
    return false;
}
