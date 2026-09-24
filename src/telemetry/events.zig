//! Local decision/outcome log in LinearOne's event format v1 (JSON Lines,
//! append-only; see LinearOne's EVENTS.md). Formatting is pure and
//! unit-tested in test/events_test.zig; `FileSink` is the thin append seam.
//! Logging is best-effort: a write failure never affects the agent.
const std = @import("std");

pub const DecisionRecord = struct {
    id: []const u8,
    ts_seconds: i64,
    point: []const u8,
    labels: []const []const u8,
    label: []const u8,
    engine: []const u8,
    /// Downstream model the decision resolved to, when there is one.
    model: ?[]const u8 = null,
    /// The classified input. Omitted unless the user opted into text.
    text: ?[]const u8 = null,
    /// Hashed even when `text` is omitted, so decisions stay countable.
    hashed_text: []const u8,
};

pub const OutcomeRecord = struct {
    decision_id: []const u8,
    ts_seconds: i64,
    label: []const u8,
    strength: enum { explicit, implicit },
    signal: []const u8,
};

/// "2026-09-24T10:15:00Z" into `buf`. Pre-1970 input clamps to the epoch.
pub fn formatRfc3339(buf: *[20]u8, seconds: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// One `decision` line, trailing newline included. Caller frees.
pub fn formatDecision(allocator: std.mem.Allocator, d: DecisionRecord) ![]u8 {
    var ts_buf: [20]u8 = undefined;
    const hash = sha256Hex(d.hashed_text);
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .v = 1,
        .type = "decision",
        .id = d.id,
        .ts = formatRfc3339(&ts_buf, d.ts_seconds),
        .point = d.point,
        .labels = d.labels,
        .label = d.label,
        .engine = d.engine,
        .model = d.model,
        .text = d.text,
        .text_sha256 = @as([]const u8, &hash),
    }, .{ .emit_null_optional_fields = false });
    defer allocator.free(body);
    return std.fmt.allocPrint(allocator, "{s}\n", .{body});
}

/// One `outcome` line, trailing newline included. Caller frees.
pub fn formatOutcome(allocator: std.mem.Allocator, o: OutcomeRecord) ![]u8 {
    var ts_buf: [20]u8 = undefined;
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .v = 1,
        .type = "outcome",
        .decision_id = o.decision_id,
        .ts = formatRfc3339(&ts_buf, o.ts_seconds),
        .label = o.label,
        .strength = @tagName(o.strength),
        .signal = o.signal,
    }, .{});
    defer allocator.free(body);
    return std.fmt.allocPrint(allocator, "{s}\n", .{body});
}

/// Where finished lines go. Same ptr + fn-pointer style as loop.Reporter;
/// `append` MUST NOT fail.
pub const Sink = struct {
    ptr: *anyopaque,
    appendFn: *const fn (ptr: *anyopaque, line: []const u8) void,

    pub fn append(self: Sink, line: []const u8) void {
        self.appendFn(self.ptr, line);
    }
};

/// Appends to `<workspace>/.opennull/events.jsonl`, creating it on first
/// use. Real-filesystem seam; errors are swallowed by design.
pub const FileSink = struct {
    io: std.Io,
    dir_path: []const u8,
    file_path: []const u8,

    pub fn sink(self: *FileSink) Sink {
        return .{ .ptr = self, .appendFn = appendLine };
    }

    fn appendLine(ptr: *anyopaque, line: []const u8) void {
        const self: *FileSink = @ptrCast(@alignCast(ptr));
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, self.dir_path) catch return;
        const file = cwd.createFile(self.io, self.file_path, .{ .truncate = false }) catch return;
        defer file.close(self.io);
        const end = file.length(self.io) catch return;
        file.writePositionalAll(self.io, line, end) catch return;
    }
};

/// Stamps ids/timestamps and formats records onto a Sink.
pub const EventLog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sink: Sink,
    record_text: bool,
    counter: u32 = 0,
    /// Test seam: fixed clock in seconds; null reads the real clock.
    fixed_now: ?i64 = null,

    pub fn nowSeconds(self: *EventLog) i64 {
        if (self.fixed_now) |t| return t;
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    /// "<wall-clock ns, hex>-<per-process counter>": unique within the file
    /// unless two processes log in the same nanosecond.
    pub fn nextId(self: *EventLog, buf: *[32]u8) []const u8 {
        self.counter += 1;
        const ns: i96 = if (self.fixed_now) |t| @as(i96, t) * std.time.ns_per_s else std.Io.Timestamp.now(self.io, .real).toNanoseconds();
        return std.fmt.bufPrint(buf, "{x}-{d}", .{ @as(u64, @intCast(@max(ns, 0))), self.counter }) catch unreachable;
    }

    /// Best-effort: allocation or formatting failure just skips the line.
    pub fn decision(self: *EventLog, d: DecisionRecord) void {
        var rec = d;
        if (!self.record_text) rec.text = null;
        const line = formatDecision(self.allocator, rec) catch return;
        defer self.allocator.free(line);
        self.sink.append(line);
    }

    pub fn outcome(self: *EventLog, o: OutcomeRecord) void {
        const line = formatOutcome(self.allocator, o) catch return;
        defer self.allocator.free(line);
        self.sink.append(line);
    }
};
