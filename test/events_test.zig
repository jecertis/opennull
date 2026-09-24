//! BDD spec for src/telemetry/events.zig and the logging approver in
//! src/cli/approval.zig — records match LinearOne's event format v1.
const std = @import("std");
const opennull = @import("opennull");
const events = opennull.telemetry.events;
const approval = opennull.cli.approval;

/// In-memory Sink collecting every appended line.
const MemorySink = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn sink(self: *MemorySink) events.Sink {
        return .{ .ptr = self, .appendFn = append };
    }
    fn append(ptr: *anyopaque, line: []const u8) void {
        const self: *MemorySink = @ptrCast(@alignCast(ptr));
        self.buf.appendSlice(std.testing.allocator, line) catch {};
    }
    fn lines(self: *MemorySink) usize {
        return std.mem.count(u8, self.buf.items, "\n");
    }
};

fn parseLine(text: []const u8, index: usize) !std.json.Parsed(std.json.Value) {
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == index) return std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    }
    return error.NoSuchLine;
}

fn str(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return obj.get(key).?.string;
}

// Scenario: Given a Unix time, when formatted, then it is RFC 3339 UTC.
test "timestamps are RFC 3339 in UTC" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-24T10:15:00Z", events.formatRfc3339(&buf, 1790244900));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", events.formatRfc3339(&buf, 0));
}

// Scenario: Given "abc", when hashed, then it matches the SHA-256 test vector.
test "text hash is lowercase hex SHA-256" {
    const h = events.sha256Hex("abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &h);
}

// Scenario: Given a decision with a model and text, when formatted, then it
// is one v1 JSON line with every required field and no confidence field.
test "decision line carries the v1 fields" {
    const labels = [_][]const u8{ "fast", "powerful" };
    const line = try events.formatDecision(std.testing.allocator, .{
        .id = "d1",
        .ts_seconds = 1790244900,
        .point = "router",
        .labels = &labels,
        .label = "fast",
        .engine = "opennull-keyword@0.1.2",
        .model = "llama3.2",
        .text = "rename the helper",
        .hashed_text = "rename the helper",
    });
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));

    const parsed = try parseLine(line, 0);
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), o.get("v").?.integer);
    try std.testing.expectEqualStrings("decision", str(o, "type"));
    try std.testing.expectEqualStrings("2026-09-24T10:15:00Z", str(o, "ts"));
    try std.testing.expectEqualStrings("router", str(o, "point"));
    try std.testing.expectEqual(@as(usize, 2), o.get("labels").?.array.items.len);
    try std.testing.expectEqualStrings("llama3.2", str(o, "model"));
    try std.testing.expectEqualStrings("rename the helper", str(o, "text"));
    const h = events.sha256Hex("rename the helper");
    try std.testing.expectEqualStrings(&h, str(o, "text_sha256"));
    try std.testing.expect(o.get("confidence") == null);
}

// Scenario: Given an engine with a probability, when its decision is
// formatted, then confidence is written.
test "decision line carries confidence when the engine has one" {
    const labels = [_][]const u8{ "fast", "powerful" };
    const line = try events.formatDecision(std.testing.allocator, .{ .id = "d2", .ts_seconds = 0, .point = "router", .labels = &labels, .label = "powerful", .confidence = 0.75, .engine = "linearone-ngram@afae315d", .hashed_text = "x" });
    defer std.testing.allocator.free(line);
    const parsed = try parseLine(line, 0);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 0.75), parsed.value.object.get("confidence").?.float);
}

// Scenario: Given text recording is off, when a decision is logged, then
// the text is dropped but its hash is still written.
test "record_text off keeps the hash, drops the text" {
    var mem = MemorySink{};
    defer mem.buf.deinit(std.testing.allocator);
    var log = events.EventLog{ .allocator = std.testing.allocator, .io = undefined, .sink = mem.sink(), .record_text = false, .fixed_now = 1790244900 };
    const labels = [_][]const u8{ "approve", "reject" };
    log.decision(.{ .id = "d1", .ts_seconds = 1790244900, .point = "tool_guard", .labels = &labels, .label = "reject", .engine = "e@1", .text = "secret", .hashed_text = "secret" });

    const parsed = try parseLine(mem.buf.items, 0);
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expect(o.get("text") == null);
    const h = events.sha256Hex("secret");
    try std.testing.expectEqualStrings(&h, str(o, "text_sha256"));
}

fn runApproval(answer: []const u8, mem: *MemorySink) !bool {
    var reader: std.Io.Reader = .fixed(answer);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var console = approval.ConsoleApprover{ .reader = &reader, .w = &out.writer };
    var log = events.EventLog{ .allocator = std.testing.allocator, .io = undefined, .sink = mem.sink(), .record_text = true, .fixed_now = 1790244900 };
    var logging = approval.LoggingApprover{ .console = &console, .log = &log };

    const input = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"path\":\"a.txt\"}", .{});
    defer input.deinit();
    return logging.approver().approve("file_write", input.value);
}

// Scenario: Given the user types "y", when a write is gated, then it is
// approved and the log holds a tool_guard decision plus an explicit
// edit_approved outcome pointing at it.
test "approved edit logs decision and explicit approve outcome" {
    var mem = MemorySink{};
    defer mem.buf.deinit(std.testing.allocator);
    try std.testing.expect(try runApproval("y\n", &mem));
    try std.testing.expectEqual(@as(usize, 2), mem.lines());

    const d = try parseLine(mem.buf.items, 0);
    defer d.deinit();
    const o = try parseLine(mem.buf.items, 1);
    defer o.deinit();
    try std.testing.expectEqualStrings("tool_guard", str(d.value.object, "point"));
    try std.testing.expectEqualStrings("reject", str(d.value.object, "label"));
    try std.testing.expectEqualStrings("file_write {\"path\":\"a.txt\"}", str(d.value.object, "text"));
    try std.testing.expectEqualStrings(str(d.value.object, "id"), str(o.value.object, "decision_id"));
    try std.testing.expectEqualStrings("approve", str(o.value.object, "label"));
    try std.testing.expectEqualStrings("explicit", str(o.value.object, "strength"));
    try std.testing.expectEqualStrings("edit_approved", str(o.value.object, "signal"));
}

// Scenario: Given the user types "n", when a write is gated, then it is
// declined with an explicit edit_rejected outcome.
test "rejected edit logs explicit reject outcome" {
    var mem = MemorySink{};
    defer mem.buf.deinit(std.testing.allocator);
    try std.testing.expect(!try runApproval("n\n", &mem));
    const o = try parseLine(mem.buf.items, 1);
    defer o.deinit();
    try std.testing.expectEqualStrings("reject", str(o.value.object, "label"));
    try std.testing.expectEqualStrings("edit_rejected", str(o.value.object, "signal"));
}

// Scenario: Given stdin is already at EOF (e.g. a piped `run`), when a write
// is gated, then it is declined, and only the decision is logged: no user
// answered, so no outcome may be invented.
test "EOF declines without inventing an outcome" {
    var mem = MemorySink{};
    defer mem.buf.deinit(std.testing.allocator);
    try std.testing.expect(!try runApproval("", &mem));
    try std.testing.expectEqual(@as(usize, 1), mem.lines());
}
