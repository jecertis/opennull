//! Terminal approval adapter. Core policy stays I/O-free; this is the small
//! CLI seam that turns a y/N response into the loop's Approver callback.
const std = @import("std");
const loop = @import("../agent/loop.zig");

pub const ConsoleApprover = struct {
    reader: *std.Io.Reader,
    w: *std.Io.Writer,

    pub fn approver(self: *ConsoleApprover) loop.Approver {
        return .{ .ptr = self, .approveFn = approve };
    }

    fn approve(ptr: *anyopaque, _: []const u8, _: std.json.Value) bool {
        const self: *ConsoleApprover = @ptrCast(@alignCast(ptr));
        self.w.print("approve? [y/N] ", .{}) catch return false;
        self.w.flush() catch return false;
        const answer = (self.reader.takeDelimiter('\n') catch return false) orelse return false;
        return answer.len == 1 and (answer[0] == 'y' or answer[0] == 'Y');
    }
};
