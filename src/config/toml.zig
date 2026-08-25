//! Minimal TOML-subset parser covering only what config.toml needs — see
//! test/toml_test.zig for the exact scenarios and the deferred-features note.
const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: std.ArrayListUnmanaged(*Value),
    table: *Table,
};

pub const Table = std.StringHashMapUnmanaged(*Value);

pub const ParseError = error{
    InvalidKeyValueLine,
    InvalidValue,
    KeyExistsAsNonTable,
    KeyExistsAsNonArray,
    EmptyTableHeader,
} || std.mem.Allocator.Error;

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Table,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

pub fn parse(child_allocator: std.mem.Allocator, contents: []const u8) ParseError!Document {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = try a.create(Table);
    root.* = .empty;
    var current: *Table = root;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "[[") and std.mem.endsWith(u8, line, "]]")) {
            const path_str = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
            current = try appendArrayTable(a, root, path_str);
            continue;
        }
        if (std.mem.startsWith(u8, line, "[") and std.mem.endsWith(u8, line, "]")) {
            const path_str = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            current = try ensureTablePath(a, root, path_str);
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidKeyValueLine;
        const raw_key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (raw_key.len == 0) return error.InvalidKeyValueLine;

        const key = try unquote(a, raw_key);
        const value = try parseValue(a, raw_val);
        try current.put(a, key, value);
    }

    return Document{ .arena = arena, .root = root };
}

// -- accessors ---------------------------------------------------------

pub fn getString(table: *Table, key: []const u8) ?[]const u8 {
    const v = table.get(key) orelse return null;
    return switch (v.*) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(table: *Table, key: []const u8) ?i64 {
    const v = table.get(key) orelse return null;
    return switch (v.*) {
        .integer => |i| i,
        else => null,
    };
}

pub fn getFloat(table: *Table, key: []const u8) ?f64 {
    const v = table.get(key) orelse return null;
    return switch (v.*) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

pub fn getBool(table: *Table, key: []const u8) ?bool {
    const v = table.get(key) orelse return null;
    return switch (v.*) {
        .boolean => |b| b,
        else => null,
    };
}

pub fn getTable(table: *Table, key: []const u8) ?*Table {
    const v = table.get(key) orelse return null;
    return switch (v.*) {
        .table => |t| t,
        else => null,
    };
}

/// Raw inline-array elements (as `*Value`), e.g. for a string array like
/// `allow = ["a", "b"]`. Caller inspects each element's active tag.
pub fn getArray(table: *Table, key: []const u8) ?[]const *Value {
    const v = table.get(key) orelse return null;
    return switch (v.*) {
        .array => |list| list.items,
        else => null,
    };
}

/// Collects the tables inside an `[[array]]` (or an inline array of
/// tables) at `key`, in document order. Returns `null` if the key is
/// absent; returns an allocator-owned slice (caller frees it) otherwise —
/// the tables themselves remain owned by the document's arena.
pub fn getArrayOfTables(
    allocator: std.mem.Allocator,
    table: *Table,
    key: []const u8,
) !?[]const *Table {
    const v = table.get(key) orelse return null;
    const list = switch (v.*) {
        .array => |l| l,
        else => return null,
    };
    var out = try std.ArrayListUnmanaged(*Table).initCapacity(allocator, list.items.len);
    errdefer out.deinit(allocator);
    for (list.items) |item| {
        switch (item.*) {
            .table => |t| try out.append(allocator, t),
            else => {},
        }
    }
    return try out.toOwnedSlice(allocator);
}

// -- internals -----------------------------------------------------------

fn unquote(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return a.dupe(u8, raw[1 .. raw.len - 1]);
    }
    return a.dupe(u8, raw);
}

/// Splits a table-header path like `providers.anthropic` or
/// `pricing."claude-sonnet-5"` into segments, respecting quoted segments
/// that may themselves contain '.'.
fn splitPath(a: std.mem.Allocator, path_str: []const u8) ![]const []const u8 {
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < path_str.len) {
        if (path_str[i] == '"') {
            const start = i + 1;
            var j = start;
            while (j < path_str.len and path_str[j] != '"') : (j += 1) {}
            try segments.append(a, try a.dupe(u8, path_str[start..j]));
            i = if (j < path_str.len) j + 1 else j;
        } else {
            var j = i;
            while (j < path_str.len and path_str[j] != '.') : (j += 1) {}
            const seg = std.mem.trim(u8, path_str[i..j], " \t");
            try segments.append(a, try a.dupe(u8, seg));
            i = j;
        }
        if (i < path_str.len and path_str[i] == '.') i += 1;
    }
    if (segments.items.len == 0) return error.EmptyTableHeader;
    return segments.toOwnedSlice(a);
}

fn ensureTablePath(a: std.mem.Allocator, root: *Table, path_str: []const u8) !*Table {
    const segs = try splitPath(a, path_str);
    var t = root;
    for (segs) |seg| {
        t = try ensureChildTable(a, t, seg);
    }
    return t;
}

fn ensureChildTable(a: std.mem.Allocator, t: *Table, seg: []const u8) !*Table {
    if (t.get(seg)) |existing| {
        return switch (existing.*) {
            .table => |child| child,
            else => error.KeyExistsAsNonTable,
        };
    }
    const child = try a.create(Table);
    child.* = .empty;
    const val = try a.create(Value);
    val.* = .{ .table = child };
    try t.put(a, seg, val);
    return child;
}

fn appendArrayTable(a: std.mem.Allocator, root: *Table, path_str: []const u8) !*Table {
    const segs = try splitPath(a, path_str);
    var t = root;
    for (segs[0 .. segs.len - 1]) |seg| {
        t = try ensureChildTable(a, t, seg);
    }
    const last = segs[segs.len - 1];

    const new_table = try a.create(Table);
    new_table.* = .empty;
    const table_val = try a.create(Value);
    table_val.* = .{ .table = new_table };

    if (t.get(last)) |existing| {
        switch (existing.*) {
            .array => |*list| try list.append(a, table_val),
            else => return error.KeyExistsAsNonArray,
        }
    } else {
        var list: std.ArrayListUnmanaged(*Value) = .empty;
        try list.append(a, table_val);
        const arr_val = try a.create(Value);
        arr_val.* = .{ .array = list };
        try t.put(a, last, arr_val);
    }
    return new_table;
}

fn parseValue(a: std.mem.Allocator, raw: []const u8) !*Value {
    const v = try a.create(Value);

    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        v.* = .{ .string = try a.dupe(u8, raw[1 .. raw.len - 1]) };
        return v;
    }
    if (std.mem.eql(u8, raw, "true")) {
        v.* = .{ .boolean = true };
        return v;
    }
    if (std.mem.eql(u8, raw, "false")) {
        v.* = .{ .boolean = false };
        return v;
    }
    if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') {
        const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t");
        var list: std.ArrayListUnmanaged(*Value) = .empty;
        if (inner.len > 0) {
            var it = std.mem.splitScalar(u8, inner, ',');
            while (it.next()) |item_raw| {
                const item = std.mem.trim(u8, item_raw, " \t");
                if (item.len == 0) continue;
                try list.append(a, try parseValue(a, item));
            }
        }
        v.* = .{ .array = list };
        return v;
    }
    if (std.fmt.parseInt(i64, raw, 10)) |i| {
        v.* = .{ .integer = i };
        return v;
    } else |_| {}
    if (std.fmt.parseFloat(f64, raw)) |f| {
        v.* = .{ .float = f };
        return v;
    } else |_| {}

    return error.InvalidValue;
}
