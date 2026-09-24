//! LinearOne n-gram router engine, format v1 (LinearOne's NGRAM_FORMAT.md):
//! a validated weight table of word and word-pair features scored with
//! TF-IDF and a linear model, all in f64. Pure: `parse` and `score` do no
//! I/O. Conformance against LinearOne's reference vectors lives in
//! test/ngram_test.zig.
const std = @import("std");

pub const max_input_bytes = 4096;
const min_token_bytes = 2;
const ngram_max = 2;
const magic = "L1NG";

pub const ParseError = error{
    BadMagic,
    UnsupportedSettings,
    Truncated,
    FeaturesNotIncreasing,
    TrailingBytes,
} || std.mem.Allocator.Error;

pub const Feature = struct {
    key: []const u8,
    idf: f64,
    coef: f64,
};

pub const Model = struct {
    labels: [2][]const u8,
    bias: f64,
    cut: f64,
    /// Sorted strictly by raw bytes; keys point into the parsed buffer.
    features: []const Feature,
    /// "linearone-ngram@<first 8 hex of sha256(file)>".
    engine_buf: [24]u8,

    pub fn engine(self: *const Model) []const u8 {
        return &self.engine_buf;
    }

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        allocator.free(self.features);
    }

    fn find(self: *const Model, key: []const u8) ?Feature {
        var lo: usize = 0;
        var hi: usize = self.features.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.features[mid].key, key)) {
                .eq => return self.features[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
};

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ParseError![]const u8 {
        if (self.bytes.len - self.pos < n) return error.Truncated;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }
    fn int(self: *Cursor, comptime T: type) ParseError!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    fn float(self: *Cursor) ParseError!f64 {
        return @as(f32, @bitCast(try self.int(u32)));
    }
};

/// Validates and indexes an .l1ng file. `bytes` must outlive the Model
/// (feature keys and labels point into it). Caller calls `deinit`.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Model {
    var c = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try c.take(4), magic)) return error.BadMagic;
    const version = try c.int(u32);
    const n_max = try c.int(u8);
    const min_tok = try c.int(u8);
    const max_in = try c.int(u16);
    if (version != 1 or n_max != ngram_max or min_tok != min_token_bytes or max_in != max_input_bytes)
        return error.UnsupportedSettings;

    var labels: [2][]const u8 = undefined;
    for (&labels) |*l| l.* = try c.take(try c.int(u8));
    const bias = try c.float();
    const cut = try c.float();
    const n = try c.int(u32);

    // Every feature takes at least 10 bytes; reject absurd counts before allocating.
    if (n > (bytes.len - c.pos) / 10) return error.Truncated;
    const features = try allocator.alloc(Feature, n);
    errdefer allocator.free(features);
    for (features, 0..) |*f, i| {
        const key = try c.take(try c.int(u16));
        if (i > 0 and std.mem.order(u8, features[i - 1].key, key) != .lt) return error.FeaturesNotIncreasing;
        f.* = .{ .key = key, .idf = try c.float(), .coef = try c.float() };
    }
    if (c.pos != bytes.len) return error.TrailingBytes;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var engine_buf: [24]u8 = undefined;
    const hex = std.fmt.bytesToHex(digest[0..4].*, .lower);
    _ = std.fmt.bufPrint(&engine_buf, "linearone-ngram@{s}", .{&hex}) catch unreachable;

    return .{ .labels = labels, .bias = bias, .cut = cut, .features = features, .engine_buf = engine_buf };
}

fn isTokenByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b >= 0x80;
}

/// Lowercased copy of the first 4,096 input bytes (ASCII A–Z only) into
/// `buf`, then the kept tokens (>= 2 bytes) as slices of `buf`.
pub fn tokenize(allocator: std.mem.Allocator, buf: *[max_input_bytes]u8, text: []const u8) ![][]const u8 {
    const raw = buf[0..@min(text.len, max_input_bytes)];
    for (raw, text[0..raw.len]) |*dst, b| dst.* = if (b >= 'A' and b <= 'Z') b + 0x20 else b;

    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer tokens.deinit(allocator);
    var start: ?usize = null;
    for (raw, 0..) |b, i| {
        if (isTokenByte(b)) {
            if (start == null) start = i;
        } else if (start) |s| {
            if (i - s >= min_token_bytes) try tokens.append(allocator, raw[s..i]);
            start = null;
        }
    }
    if (start) |s| if (raw.len - s >= min_token_bytes) try tokens.append(allocator, raw[s..]);
    return tokens.toOwnedSlice(allocator);
}

pub const Scored = struct {
    /// Index into `Model.labels`.
    label: u1,
    score: f64,
    /// Probability of labels[1].
    probability: f64,

    /// Probability of the chosen label.
    pub fn confidence(self: Scored) f64 {
        return if (self.label == 1) self.probability else 1 - self.probability;
    }
};

/// Scores `text`. `allocator` is used only for scratch and is fully freed.
pub fn score(model: *const Model, allocator: std.mem.Allocator, text: []const u8) !Scored {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [max_input_bytes]u8 = undefined;
    const tokens = try tokenize(arena, &buf, text);

    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (tokens) |t| (try counts.getOrPutValue(arena, t, 0)).value_ptr.* += 1;
    if (tokens.len > 1) for (tokens[0 .. tokens.len - 1], tokens[1..]) |a, b| {
        const pair = try std.mem.concat(arena, u8, &.{ a, " ", b });
        (try counts.getOrPutValue(arena, pair, 0)).value_ptr.* += 1;
    };

    var dot: f64 = 0;
    var sq: f64 = 0;
    var it = counts.iterator();
    while (it.next()) |e| {
        const f = model.find(e.key_ptr.*) orelse continue;
        const value = (1 + @log(@as(f64, @floatFromInt(e.value_ptr.*)))) * f.idf;
        dot += f.coef * value;
        sq += value * value;
    }
    const norm = @sqrt(sq);
    const s = model.bias + (if (norm > 0) dot / norm else 0);
    return .{
        .label = if (s < model.cut) 0 else 1,
        .score = s,
        .probability = 1 / (1 + @exp(-s)),
    };
}

/// Matched features and their counts, for conformance tests and debugging.
/// Keys are allocated in `arena`.
pub fn matched(model: *const Model, arena: std.mem.Allocator, text: []const u8) !std.StringArrayHashMapUnmanaged(u32) {
    const buf = try arena.create([max_input_bytes]u8);
    const tokens = try tokenize(arena, buf, text);
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (tokens, 0..) |t, i| {
        if (model.find(t) != null) (try counts.getOrPutValue(arena, t, 0)).value_ptr.* += 1;
        if (i + 1 < tokens.len) {
            const pair = try std.mem.concat(arena, u8, &.{ t, " ", tokens[i + 1] });
            if (model.find(pair) != null) (try counts.getOrPutValue(arena, pair, 0)).value_ptr.* += 1;
        }
    }
    return counts;
}
