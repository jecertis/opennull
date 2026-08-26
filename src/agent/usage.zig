//! Session-level token accounting: accumulates per-request usage reported
//! by providers and prices it against the [pricing] table from
//! config.toml. See test/usage_test.zig.
const std = @import("std");
const provider = @import("../provider/provider.zig");
const config_mod = @import("../config/config.zig");

pub const PriceEntry = config_mod.PriceEntry;

pub const UsageTotals = struct {
    requests: u32 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,

    pub fn add(self: *UsageTotals, u: provider.Usage) void {
        self.requests += 1;
        self.input_tokens += u.input_tokens;
        self.output_tokens += u.output_tokens;
    }
};

/// Cost in dollars for `totals` at `model`'s configured rates, or null when
/// no usable pricing entry exists (missing entry, all rates null).
/// Rates are $ per million tokens (`input`/`output`); `flat` bills once
/// per request.
pub fn costOf(
    pricing: []const PriceEntry,
    model: []const u8,
    totals: UsageTotals,
) ?f64 {
    var entry: ?PriceEntry = null;
    for (pricing) |p| {
        if (std.mem.eql(u8, p.model, model)) {
            entry = p;
            break;
        }
    }
    const e = entry orelse return null;
    if (e.input == null and e.output == null and e.flat == null) return null;

    var cost: f64 = 0;
    if (e.input) |rate| cost += @as(f64, @floatFromInt(totals.input_tokens)) * rate / 1_000_000;
    if (e.output) |rate| cost += @as(f64, @floatFromInt(totals.output_tokens)) * rate / 1_000_000;
    if (e.flat) |fee| cost += fee * @as(f64, @floatFromInt(totals.requests));
    return cost;
}
