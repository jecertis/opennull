//! Terminal approval adapter. Core policy stays I/O-free; this is the small
//! CLI seam that turns a y/N response into the loop's Approver callback.
const std = @import("std");
const loop = @import("../agent/loop.zig");
const events = @import("../telemetry/events.zig");
const version = @import("../root.zig").version;

pub const ConsoleApprover = struct {
    reader: *std.Io.Reader,
    w: *std.Io.Writer,
    /// Whether the last prompt got a typed answer. False after EOF or a read
    /// error, which decline without being a user's decision.
    answered: bool = false,
    /// Running count of approved calls, so callers can tell whether a turn
    /// ended with an accepted edit.
    approved_count: u32 = 0,

    pub fn approver(self: *ConsoleApprover) loop.Approver {
        return .{ .ptr = self, .approveFn = approve };
    }

    fn approve(ptr: *anyopaque, name: []const u8, input: std.json.Value) bool {
        const self: *ConsoleApprover = @ptrCast(@alignCast(ptr));
        return self.ask(name, input);
    }

    pub fn ask(self: *ConsoleApprover, _: []const u8, _: std.json.Value) bool {
        self.answered = false;
        self.w.print("approve? [y/N] ", .{}) catch return false;
        self.w.flush() catch return false;
        const answer = (self.reader.takeDelimiter('\n') catch return false) orelse return false;
        self.answered = true;
        const ok = answer.len == 1 and (answer[0] == 'y' or answer[0] == 'Y');
        if (ok) self.approved_count += 1;
        return ok;
    }
};

/// Wraps ConsoleApprover and records each approval prompt as a `tool_guard`
/// decision plus, when the user actually answered, an explicit outcome.
/// The static policy never auto-approves, so its decision is always
/// "reject" (withhold until a human approves) with no confidence.
pub const LoggingApprover = struct {
    console: *ConsoleApprover,
    log: *events.EventLog,

    pub const labels = [_][]const u8{ "approve", "reject" };
    pub const engine = "opennull-tool-policy@" ++ version;

    pub fn approver(self: *LoggingApprover) loop.Approver {
        return .{ .ptr = self, .approveFn = approve };
    }

    fn approve(ptr: *anyopaque, name: []const u8, input: std.json.Value) bool {
        const self: *LoggingApprover = @ptrCast(@alignCast(ptr));
        const a = self.log.allocator;

        // The classified input is the tool call itself: "<name> <json>".
        const input_json = std.json.Stringify.valueAlloc(a, input, .{}) catch null;
        defer if (input_json) |s| a.free(s);
        const call_text = std.fmt.allocPrint(a, "{s} {s}", .{ name, input_json orelse "" }) catch null;
        defer if (call_text) |s| a.free(s);

        var id_buf: [32]u8 = undefined;
        const id = self.log.nextId(&id_buf);
        if (call_text) |text| self.log.decision(.{
            .id = id,
            .ts_seconds = self.log.nowSeconds(),
            .point = "tool_guard",
            .labels = &labels,
            .label = "reject",
            .engine = engine,
            .text = text,
            .hashed_text = text,
        });

        const ok = self.console.ask(name, input);
        if (call_text != null and self.console.answered) self.log.outcome(.{
            .decision_id = id,
            .ts_seconds = self.log.nowSeconds(),
            .label = if (ok) "approve" else "reject",
            .strength = .explicit,
            .signal = if (ok) "edit_approved" else "edit_rejected",
        });
        return ok;
    }
};

/// The approver a CLI command hands to the loop: the console prompt,
/// optionally wrapped in the event log. Must not move after
/// `enableEventLog` (it holds pointers into itself).
pub const SessionApprover = struct {
    console: ConsoleApprover,
    allocator: ?std.mem.Allocator = null,
    dir_path: []u8 = &.{},
    file_path: []u8 = &.{},
    file_sink: events.FileSink = undefined,
    log: events.EventLog = undefined,
    logging: LoggingApprover = undefined,

    /// Logs to `<workspace_root>/.opennull/events.jsonl`.
    pub fn enableEventLog(
        self: *SessionApprover,
        allocator: std.mem.Allocator,
        io: std.Io,
        workspace_root: []const u8,
        record_text: bool,
    ) !void {
        self.dir_path = try std.fs.path.join(allocator, &.{ workspace_root, ".opennull" });
        errdefer allocator.free(self.dir_path);
        self.file_path = try std.fs.path.join(allocator, &.{ self.dir_path, "events.jsonl" });
        self.allocator = allocator;
        self.file_sink = .{ .io = io, .dir_path = self.dir_path, .file_path = self.file_path };
        self.log = .{ .allocator = allocator, .io = io, .sink = self.file_sink.sink(), .record_text = record_text };
        self.logging = .{ .console = &self.console, .log = &self.log };
    }

    pub fn approver(self: *SessionApprover) loop.Approver {
        return if (self.allocator != null) self.logging.approver() else self.console.approver();
    }

    /// The event log, when the user opted in.
    pub fn eventLog(self: *SessionApprover) ?*events.EventLog {
        return if (self.allocator != null) &self.log else null;
    }

    pub fn deinit(self: *SessionApprover) void {
        const a = self.allocator orelse return;
        a.free(self.file_path);
        a.free(self.dir_path);
    }
};
