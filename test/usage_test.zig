//! BDD spec for src/agent/usage.zig — session token accounting and cost
//! computation against the [pricing] table from config.toml.
const std = @import("std");
const opennull = @import("opennull");
const usage = opennull.agent.usage;
const config_mod = opennull.config.config;

// Scenario: Given several per-request usages (a tool-using turn hits the
// API multiple times), when each is added, then requests and both token
// counters accumulate.
test "UsageTotals accumulates across requests" {
    var totals: usage.UsageTotals = .{};
    totals.add(.{ .input_tokens = 100, .output_tokens = 10 });
    totals.add(.{ .input_tokens = 250, .output_tokens = 32 });
    try std.testing.expectEqual(@as(u32, 2), totals.requests);
    try std.testing.expectEqual(@as(u64, 350), totals.input_tokens);
    try std.testing.expectEqual(@as(u64, 42), totals.output_tokens);
}

// Scenario: Given a pricing entry with input/output rates ($/Mtok), when a
// session's tokens are priced, then the cost is in/out * rate / 1e6.
test "costOf prices input and output at per-million rates" {
    const pricing = [_]config_mod.PriceEntry{.{ .model = "m", .input = 3.0, .output = 15.0, .flat = null }};
    var totals: usage.UsageTotals = .{};
    totals.add(.{ .input_tokens = 1_000_000, .output_tokens = 100_000 });
    const cost = usage.costOf(&pricing, "m", totals).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 + 1.5), cost, 0.000001);
}

// Scenario: Given an entry with a flat per-request fee, when priced, then
// the fee multiplies by the REQUEST COUNT, not the token count.
test "costOf applies flat fee once per request" {
    const pricing = [_]config_mod.PriceEntry{.{ .model = "m", .input = null, .output = null, .flat = 0.01 }};
    var totals: usage.UsageTotals = .{};
    totals.add(.{ .input_tokens = 10, .output_tokens = 5 });
    totals.add(.{ .input_tokens = 10, .output_tokens = 5 });
    const cost = usage.costOf(&pricing, "m", totals).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), cost, 0.000001);
}

// Scenario: Given a model with no pricing entry, when priced, then the
// result is null rather than a silently-zero cost.
test "costOf returns null for an unpriced model" {
    const pricing = [_]config_mod.PriceEntry{.{ .model = "other", .input = 3.0, .output = null, .flat = null }};
    const totals: usage.UsageTotals = .{};
    try std.testing.expectEqual(@as(?f64, null), usage.costOf(&pricing, "unpriced", totals));
}

// Scenario: Given an entry that carries no rates at all, when priced, then
// it counts as unusable and yields null instead of $0.
test "costOf returns null for an entry with no rates" {
    const pricing = [_]config_mod.PriceEntry{.{ .model = "m", .input = null, .output = null, .flat = null }};
    var totals: usage.UsageTotals = .{};
    totals.add(.{ .input_tokens = 5, .output_tokens = 5 });
    try std.testing.expectEqual(@as(?f64, null), usage.costOf(&pricing, "m", totals));
}
