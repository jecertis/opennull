//! Server-Sent Events line decoder — the framing layer shared by every
//! provider's streaming endpoint. Feed it one raw line at a time (as read
//! from the HTTP body); it hands back one Decoded event per blank line.
//!
//! Ownership: the decoder treats its allocator as a bulk-reclaim arena —
//! decoded strings are duplicated into it and never individually freed.
//! Pass an allocator whose lifetime covers your whole streaming session.
//! See test/sse_test.zig.
const std = @import("std");

pub const Decoded = struct {
    /// Event name ("" when the stream sent data without an event field).
    event: []const u8,
    /// Joined payload of all `data:` lines in this event.
    data: []const u8,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    event_name: std.ArrayListUnmanaged(u8) = .empty,
    data: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Decoder) void {
        self.event_name.deinit(self.allocator);
        self.data.deinit(self.allocator);
    }

    fn reset(self: *Decoder) void {
        self.event_name.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
    }

    /// Returns null for lines that don't complete an event: comments
    /// (": ping"), field lines, and blank lines between events that had no
    /// fields since the last dispatch.
    pub fn feedLine(self: *Decoder, raw_line: []const u8) !?Decoded {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (line.len == 0) return self.dispatch();
        if (line[0] == ':') return null; // comment/keepalive

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        const field = line[0..colon];
        var value = line[@min(colon + 1, line.len)..];
        if (value.len > 0 and value[0] == ' ') value = value[1..]; // spec: strip ONE space

        if (std.mem.eql(u8, field, "event")) {
            try self.event_name.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, field, "data")) {
            // Spec: multiple data lines join with "\n".
            if (self.data.items.len > 0) try self.data.append(self.allocator, '\n');
            try self.data.appendSlice(self.allocator, value);
        }
        // Unknown fields ("id:", "retry:") are legal and ignored.

        return null;
    }

    fn dispatch(self: *Decoder) !?Decoded {
        if (self.event_name.items.len == 0 and self.data.items.len == 0) return null;
        const out = Decoded{
            .event = try self.allocator.dupe(u8, self.event_name.items),
            .data = try self.allocator.dupe(u8, self.data.items),
        };
        self.reset();
        return out;
    }
};
