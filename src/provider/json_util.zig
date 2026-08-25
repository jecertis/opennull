//! Hand-rolled JSON writing helpers shared by every provider that builds
//! its own request bodies (rather than std.json.Stringify) — see
//! anthropic.zig for why. Extracted here once a second provider
//! (openai_compat.zig) needed the identical logic.
const std = @import("std");

pub fn appendJsonString(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => try buf.append(a, c),
        }
    }
    try buf.append(a, '"');
}

pub fn appendJsonValue(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try buf.appendSlice(a, "null"),
        .bool => |b| try buf.appendSlice(a, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(a, "{d}", .{i});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(a, "{d}", .{f});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .number_string => |s| try buf.appendSlice(a, s),
        .string => |s| try appendJsonString(buf, a, s),
        .array => |arr| {
            try buf.append(a, '[');
            for (arr.items, 0..) |item, i| {
                if (i != 0) try buf.append(a, ',');
                try appendJsonValue(buf, a, item);
            }
            try buf.append(a, ']');
        },
        .object => |obj| {
            try buf.append(a, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.append(a, ',');
                first = false;
                try appendJsonString(buf, a, entry.key_ptr.*);
                try buf.append(a, ':');
                try appendJsonValue(buf, a, entry.value_ptr.*);
            }
            try buf.append(a, '}');
        },
    }
}

/// Renders `v` as raw JSON text (not escaped as a string), e.g. for
/// embedding as OpenAI's `arguments` field, which is itself a JSON-encoded
/// *string* containing the call's argument object.
pub fn valueToOwnedString(a: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try appendJsonValue(&buf, a, v);
    return buf.toOwnedSlice(a);
}
