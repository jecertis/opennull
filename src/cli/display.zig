//! CLI presentation helpers shared by the `run` and `chat` commands: pure
//! line formatters for tool activity and token/cost accounting, plus the
//! best-effort stdout Reporter that feeds them. Formatter specs live in
//! test/display_test.zig.
const std = @import("std");
const loop = @import("../agent/loop.zig");
const usage_mod = @import("../agent/usage.zig");

/// "[tool] file_read {\"path\":\"a.txt\"}" — the tool's name plus its
/// compact JSON input. Caller frees.
pub fn formatToolStarted(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: std.json.Value,
) ![]u8 {
    const input_json = try std.json.Stringify.valueAlloc(allocator, input, .{});
    defer allocator.free(input_json);
    return std.fmt.allocPrint(allocator, "[tool] {s} {s}", .{ name, input_json });
}

/// "[tool] file_read ok" on success; on failure only the FIRST line of the
/// detail is shown (details can be whole file contents or stack-ish text).
/// Caller frees.
pub fn formatToolFinished(
    allocator: std.mem.Allocator,
    name: []const u8,
    ok: bool,
    detail: []const u8,
) ![]u8 {
    if (ok) return std.fmt.allocPrint(allocator, "[tool] {s} ok", .{name});
    const first_line_len = std.mem.indexOfScalar(u8, detail, '\n') orelse detail.len;
    return std.fmt.allocPrint(allocator, "[tool] {s} failed: {s}", .{ name, detail[0..first_line_len] });
}

/// "tokens> <in> in / <out> out this turn | session <in> in / <out> out"
/// plus, when the model has a pricing entry, " | $<cost>". Caller frees.
pub fn formatTokensLine(
    allocator: std.mem.Allocator,
    turn_in: u64,
    turn_out: u64,
    totals: usage_mod.UsageTotals,
    cost: ?f64,
) ![]u8 {
    const base = try std.fmt.allocPrint(
        allocator,
        "tokens> {d} in / {d} out this turn | session {d} in / {d} out",
        .{ turn_in, turn_out, totals.input_tokens, totals.output_tokens },
    );
    const c = cost orelse return base;
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s} | ${d:.4}", .{ base, c });
}

/// Prints tool activity to a Writer as it happens. Best-effort: notify
/// never fails and swallows write errors (losing an activity line must not
/// abort the agent turn).
pub const StdoutReporter = struct {
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,

    pub fn reporter(self: *StdoutReporter) loop.Reporter {
        return .{ .ptr = self, .notifyFn = notify };
    }

    fn notify(ptr: *anyopaque, activity: loop.ToolActivity) void {
        const self: *StdoutReporter = @ptrCast(@alignCast(ptr));
        self.print(activity) catch {};
    }

    fn print(self: *StdoutReporter, activity: loop.ToolActivity) !void {
        const line = switch (activity) {
            .started => |e| try formatToolStarted(self.allocator, e.name, e.input),
            .finished => |e| try formatToolFinished(self.allocator, e.name, e.ok, e.detail),
        };
        defer self.allocator.free(line);
        try self.w.print("{s}\n", .{line});
        self.w.flush() catch {}; // show activity immediately, even mid-turn
    }
};
