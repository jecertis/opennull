//! Minimal `.env` parser: KEY=VALUE lines, '#' comments, blank lines
//! ignored, malformed lines skipped. See test/dotenv_test.zig for scenarios.
const std = @import("std");

/// Owns all keys and values it holds; `deinit` frees them along with the
/// underlying hash map.
pub const Map = struct {
    inner: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn get(self: *const Map, key: []const u8) ?[]const u8 {
        return self.inner.get(key);
    }

    pub fn count(self: *const Map) usize {
        return self.inner.count();
    }

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        var it = self.inner.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.inner.deinit(allocator);
    }

    fn put(self: *Map, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        if (self.inner.fetchRemove(key)) |old| {
            allocator.free(old.key);
            allocator.free(old.value);
        }
        try self.inner.put(allocator, key, value);
    }
};

/// Parses `contents` into an owned `Map`. Caller must call `map.deinit(allocator)`.
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !Map {
    var map: Map = .{};
    errdefer map.deinit(allocator);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const sep = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const raw_key = std.mem.trim(u8, line[0..sep], " \t");
        var raw_value = std.mem.trim(u8, line[sep + 1 ..], " \t");
        if (raw_key.len == 0) continue;

        if (raw_value.len >= 2 and raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') {
            raw_value = raw_value[1 .. raw_value.len - 1];
        }

        const key = try allocator.dupe(u8, raw_key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, raw_value);
        errdefer allocator.free(value);

        try map.put(allocator, key, value);
    }

    return map;
}
