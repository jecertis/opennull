//! BDD spec for src/cli/route_events.zig — router decisions and outcomes in
//! LinearOne's event format v1, as agreed with LinearOne (thread §9).
const std = @import("std");
const opennull = @import("opennull");
const events = opennull.telemetry.events;
const RouteRecorder = opennull.cli.route_events.RouteRecorder;

const MemorySink = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn sink(self: *MemorySink) events.Sink {
        return .{ .ptr = self, .appendFn = append };
    }
    fn append(ptr: *anyopaque, line: []const u8) void {
        const self: *MemorySink = @ptrCast(@alignCast(ptr));
        self.buf.appendSlice(std.testing.allocator, line) catch {};
    }
};

const Fixture = struct {
    mem: MemorySink = .{},
    log: events.EventLog = undefined,

    fn init(self: *Fixture) void {
        self.log = .{ .allocator = std.testing.allocator, .io = undefined, .sink = self.mem.sink(), .record_text = true, .fixed_now = 1790244900 };
    }
    fn deinit(self: *Fixture) void {
        self.mem.buf.deinit(std.testing.allocator);
    }
    fn lineCount(self: *Fixture) usize {
        return std.mem.count(u8, self.mem.buf.items, "\n");
    }
    fn line(self: *Fixture, index: usize) !std.json.Parsed(std.json.Value) {
        var it = std.mem.splitScalar(u8, self.mem.buf.items, '\n');
        var i: usize = 0;
        while (it.next()) |l| : (i += 1) {
            if (i == index) return std.json.parseFromSlice(std.json.Value, std.testing.allocator, l, .{});
        }
        return error.NoSuchLine;
    }
};

fn str(v: std.json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

// Scenario: Given logging is off, when the recorder is used, then nothing
// happens and nothing crashes.
test "recorder without a log is a no-op" {
    var r = RouteRecorder{ .log = null };
    r.decided("hi", .fast, "m");
    r.overridden(.powerful);
    r.turnFinished(.fast, 3);
}

// Scenario: Given a routed prompt, when recorded, then one router decision
// carries the engine's label, the resolved model and the prompt text.
test "routed prompt logs a router decision" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    var r = RouteRecorder{ .log = &f.log };
    r.decided("show me main.zig", .fast, "llama3.2:1b");

    try std.testing.expectEqual(@as(usize, 1), f.lineCount());
    const d = try f.line(0);
    defer d.deinit();
    try std.testing.expectEqualStrings("router", str(d.value, "point"));
    try std.testing.expectEqualStrings("fast", str(d.value, "label"));
    try std.testing.expectEqualStrings("llama3.2:1b", str(d.value, "model"));
    try std.testing.expectEqualStrings("show me main.zig", str(d.value, "text"));
    try std.testing.expect(std.mem.startsWith(u8, str(d.value, "engine"), "opennull-keyword@"));
}

// Scenario: Given two decisions, when the user types /powerful, then an
// explicit model_switch outcome attaches to the most recent decision.
test "override attaches explicit model_switch to the latest decision" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    var r = RouteRecorder{ .log = &f.log };
    r.decided("first", .fast, "m");
    r.decided("second", .fast, "m");
    r.overridden(.powerful);

    const second = try f.line(1);
    defer second.deinit();
    const o = try f.line(2);
    defer o.deinit();
    try std.testing.expectEqualStrings(str(second.value, "id"), str(o.value, "decision_id"));
    try std.testing.expectEqualStrings("powerful", str(o.value, "label"));
    try std.testing.expectEqualStrings("explicit", str(o.value, "strength"));
    try std.testing.expectEqualStrings("model_switch", str(o.value, "signal"));
}

// Scenario: Given no decision yet, when the user overrides, then no outcome
// is written (there is nothing to attach it to).
test "override before any decision writes nothing" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    var r = RouteRecorder{ .log = &f.log };
    r.overridden(.fast);
    try std.testing.expectEqual(@as(usize, 0), f.lineCount());
}

// Scenario: Given a fast-routed turn that ended with an approved edit, when
// it finishes, then an implicit edit_approved_on_fast outcome is written.
test "approved edit on a fast turn logs an implicit fast outcome" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    var r = RouteRecorder{ .log = &f.log };
    r.decided("rename x", .fast, "m");
    r.turnFinished(.fast, 1);

    const o = try f.line(1);
    defer o.deinit();
    try std.testing.expectEqualStrings("fast", str(o.value, "label"));
    try std.testing.expectEqualStrings("implicit", str(o.value, "strength"));
    try std.testing.expectEqualStrings("edit_approved_on_fast", str(o.value, "signal"));
}

// Scenario: Given a powerful turn with approved edits, or a fast turn with
// none, when it finishes, then silence stays silence: no outcome.
test "no implicit outcome without an approved edit on a fast turn" {
    var f = Fixture{};
    f.init();
    defer f.deinit();
    var r = RouteRecorder{ .log = &f.log };
    r.decided("design the cache", .powerful, "m");
    r.turnFinished(.powerful, 2);
    r.decided("show x", .fast, "m");
    r.turnFinished(.fast, 0);
    try std.testing.expectEqual(@as(usize, 2), f.lineCount());
}
