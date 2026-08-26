//! A chat session: prompts sent one at a time through the agent turn
//! loop, with the conversation history accumulating across calls so each
//! new request includes everything that came before. See
//! test/session_test.zig.
const std = @import("std");
const sandbox = @import("../security/sandbox.zig");
const provider = @import("../provider/provider.zig");
const loop = @import("loop.zig");
const usage_mod = @import("usage.zig");

/// Re-exported so CLI/TUI layers can talk about "a session's history"
/// without importing the loop module directly.
pub const History = loop.History;
pub const UsageTotals = usage_mod.UsageTotals;

/// Sends one user prompt as part of an ongoing session and returns the
/// assistant's final reply text (concatenated text blocks).
///
/// `allocator` MUST be a bulk-reclaim arena owned by the caller for the
/// whole session, mirroring loop.runTurn's contract: nothing here frees
/// individually — not the appended history entries (which reference the
/// providers' parsed-JSON arenas) and not the returned reply. The caller's
/// single `arena.deinit()` at session end reclaims it all transitively.
pub fn sendPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    prov: anytype,
    policy: *const sandbox.SecurityPolicy,
    history: *loop.History,
    model: []const u8,
    prompt: []const u8,
    reporter: ?loop.Reporter,
    totals: ?*usage_mod.UsageTotals,
) ![]u8 {
    // Deep-copy the prompt text: callers hand us transient buffers (e.g. a
    // stdin reader's internal buffer that the next read invalidates), while
    // history must stay valid for every later request in the session.
    const blocks = try allocator.alloc(provider.ContentBlock, 1);
    blocks[0] = .{ .text = try allocator.dupe(u8, prompt) };
    try history.append(allocator, .{ .role = .user, .content = blocks });

    const resp = try loop.runTurn(allocator, io, prov, policy, history, model, reporter, totals);

    // Copies bytes out into a fresh allocation, so it survives regardless
    // of the response arena that history now references. Deliberately do
    // NOT deinit `resp` — see runTurn's ownership contract.
    return provider.extractText(allocator, resp);
}
