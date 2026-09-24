//! Router decisions and their outcomes in LinearOne's event format v1.
//! One decision per engine-routed prompt; an explicit `model_switch`
//! outcome when the user overrides with /fast or /powerful (attached to the
//! most recent decision); an implicit `edit_approved_on_fast` outcome when a
//! fast-routed turn ends in an approved edit. Silence is never an outcome.
//! Specs: test/route_events_test.zig.
const std = @import("std");
const events = @import("../telemetry/events.zig");
const router = @import("../router/router.zig");
const version = @import("../root.zig").version;

pub const RouteRecorder = struct {
    /// Null when event logging is off: every method is then a no-op.
    log: ?*events.EventLog,
    id_buf: [32]u8 = undefined,
    /// Length of the most recent decision's id; 0 before any decision.
    id_len: usize = 0,

    pub const labels = [_][]const u8{ "fast", "powerful" };
    pub const engine = "opennull-keyword@" ++ version;

    /// Records the engine's choice for `prompt`.
    pub fn decided(self: *RouteRecorder, prompt: []const u8, hint: router.PromptHint, model: []const u8) void {
        const log = self.log orelse return;
        const id = log.nextId(&self.id_buf);
        self.id_len = id.len;
        log.decision(.{
            .id = id,
            .ts_seconds = log.nowSeconds(),
            .point = "router",
            .labels = &labels,
            .label = @tagName(hint),
            .engine = engine,
            .model = model,
            .text = prompt,
            .hashed_text = prompt,
        });
    }

    /// The user explicitly chose `hint` for the most recent decision.
    pub fn overridden(self: *RouteRecorder, hint: router.PromptHint) void {
        const log = self.log orelse return;
        if (self.id_len == 0) return;
        log.outcome(.{
            .decision_id = self.id_buf[0..self.id_len],
            .ts_seconds = log.nowSeconds(),
            .label = @tagName(hint),
            .strength = .explicit,
            .signal = "model_switch",
        });
    }

    /// Called after an engine-routed turn completes. A fast route that the
    /// user trusted with an approved edit is weak evidence "fast" was right.
    pub fn turnFinished(self: *RouteRecorder, hint: router.PromptHint, approved_edits: u32) void {
        const log = self.log orelse return;
        if (self.id_len == 0 or hint != .fast or approved_edits == 0) return;
        log.outcome(.{
            .decision_id = self.id_buf[0..self.id_len],
            .ts_seconds = log.nowSeconds(),
            .label = "fast",
            .strength = .implicit,
            .signal = "edit_approved_on_fast",
        });
    }
};
