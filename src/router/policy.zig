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
        if (std.mem.indexOf(u8, text, word) != null) return .powerful;
    }
    if (std.mem.indexOf(u8, text, "read") != null or
        std.mem.indexOf(u8, text, "show") != null or
        std.mem.indexOf(u8, text, "list") != null or
        std.mem.indexOf(u8, text, "find") != null or
        std.mem.indexOf(u8, text, "explain") != null) return .fast;
    return .powerful;
}
