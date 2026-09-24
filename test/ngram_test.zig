//! BDD spec for src/router/ngram.zig: conformance with LinearOne's
//! reference scorer (test/fixtures/ngram, copied from LinearOne's
//! bundles/ngram/router.l1ng and python/tests/ngram_vectors.json) plus the
//! loader's mandatory rejections from NGRAM_FORMAT.md §3.
const std = @import("std");
const opennull = @import("opennull");
const ngram = opennull.router_ngram;

const model_bytes = @embedFile("fixtures/ngram/router.l1ng");
const vectors_json = @embedFile("fixtures/ngram/ngram_vectors.json");

fn hexAlloc(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try a.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| _ = std.fmt.bufPrint(out[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    return out;
}

// Scenario: Given LinearOne's reference model, when parsed, then its engine
// id, labels and cut match the published vectors file.
test "reference model parses with the published identity" {
    var model = try ngram.parse(std.testing.allocator, model_bytes);
    defer model.deinit(std.testing.allocator);
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, vectors_json, .{});
    defer v.deinit();
    try std.testing.expectEqualStrings(v.value.object.get("engine").?.string, model.engine());
    try std.testing.expectEqualStrings("fast", model.labels[0]);
    try std.testing.expectEqualStrings("powerful", model.labels[1]);
    try std.testing.expectApproxEqAbs(v.value.object.get("cut").?.float, model.cut, 1e-12);
}

// Scenario: Given every reference vector, when tokenised, matched and
// scored, then tokens, matched features and label are exact and score and
// probability are within 1e-6 (the conformance bar in NGRAM_FORMAT.md §2).
test "reproduces every LinearOne reference vector" {
    var model = try ngram.parse(std.testing.allocator, model_bytes);
    defer model.deinit(std.testing.allocator);
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, vectors_json, .{});
    defer v.deinit();

    const vectors = v.value.object.get("vectors").?.array.items;
    try std.testing.expectEqual(@as(usize, 17), vectors.len);
    for (vectors) |vec| {
        const o = vec.object;
        const text = o.get("text").?.string;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var buf: [ngram.max_input_bytes]u8 = undefined;
        const tokens = try ngram.tokenize(a, &buf, text);
        const want_tokens = o.get("tokens_hex").?.array.items;
        try std.testing.expectEqual(want_tokens.len, tokens.len);
        for (tokens, want_tokens) |t, w| try std.testing.expectEqualStrings(w.string, try hexAlloc(a, t));

        const got = try ngram.matched(&model, a, text);
        const want = o.get("matched_hex").?.object;
        try std.testing.expectEqual(want.count(), got.count());
        var it = got.iterator();
        while (it.next()) |e| {
            const w = want.get(try hexAlloc(a, e.key_ptr.*)) orelse return error.UnexpectedFeature;
            try std.testing.expectEqual(@as(i64, e.value_ptr.*), w.integer);
        }

        const s = try ngram.score(&model, std.testing.allocator, text);
        try std.testing.expectApproxEqAbs(o.get("score").?.float, s.score, 1e-6);
        try std.testing.expectApproxEqAbs(o.get("probability").?.float, s.probability, 1e-6);
        try std.testing.expectEqualStrings(o.get("label").?.string, model.labels[s.label]);
    }
}

/// Builds a minimal valid file; `mutate` lets a test break one thing.
fn buildFile(a: std.mem.Allocator, keys: []const []const u8, version: u32, trailing: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "L1NG");
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, version)));
    try out.appendSlice(a, &.{ 2, 2 });
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, 4096)));
    for ([_][]const u8{ "fast", "powerful" }) |l| {
        try out.append(a, @intCast(l.len));
        try out.appendSlice(a, l);
    }
    for ([_]f32{ -1.0, 0.0 }) |f| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(f))));
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(keys.len))));
    for (keys) |k| {
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(k.len))));
        try out.appendSlice(a, k);
        for ([_]f32{ 1.0, 2.0 }) |f| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(f))));
    }
    try out.appendSlice(a, trailing);
    return out.toOwnedSlice(a);
}

// Scenario: Given a well-formed tiny file, when parsed and scored, then a
// matching feature moves the score off the bias.
test "tiny valid file scores its own feature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try buildFile(arena.allocator(), &.{ "design", "plan" }, 1, "");
    var model = try ngram.parse(std.testing.allocator, bytes);
    defer model.deinit(std.testing.allocator);
    const none = try ngram.score(&model, std.testing.allocator, "hello");
    try std.testing.expectEqual(@as(f64, -1.0), none.score);
    try std.testing.expectEqual(@as(u1, 0), none.label);
    const hit = try ngram.score(&model, std.testing.allocator, "Design it");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), hit.score, 1e-12);
    try std.testing.expectEqual(@as(u1, 1), hit.label);
}

// Scenario: Given each malformation NGRAM_FORMAT.md §3 names, when parsed,
// then the loader rejects it (so the host falls back to the keyword router).
test "loader rejects malformed files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing.allocator;

    var bad_magic = try buildFile(a, &.{"x1"}, 1, "");
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, ngram.parse(t, bad_magic));
    try std.testing.expectError(error.UnsupportedSettings, ngram.parse(t, try buildFile(a, &.{"x1"}, 2, "")));
    try std.testing.expectError(error.FeaturesNotIncreasing, ngram.parse(t, try buildFile(a, &.{ "b1", "a1" }, 1, "")));
    try std.testing.expectError(error.FeaturesNotIncreasing, ngram.parse(t, try buildFile(a, &.{ "a1", "a1" }, 1, "")));
    try std.testing.expectError(error.TrailingBytes, ngram.parse(t, try buildFile(a, &.{"a1"}, 1, "!")));
    const whole = try buildFile(a, &.{"a1"}, 1, "");
    try std.testing.expectError(error.Truncated, ngram.parse(t, whole[0 .. whole.len - 1]));
    try std.testing.expectError(error.Truncated, ngram.parse(t, "L1NG"));
}

// Scenario: Given the reference model is loaded as the router, when a
// prompt is classified, then the model decides, its engine id is reported,
// and confidence is the chosen label's probability.
test "router classify uses a loaded model" {
    const router = opennull.router;
    var m = try router.RouterModel.init(std.testing.allocator, model_bytes);
    defer m.deinit(std.testing.allocator);
    const c = router.classify(&m, std.testing.allocator, "Design a caching layer across the API, workers and database, and write a rollout plan");
    try std.testing.expectEqual(router.PromptHint.powerful, c.hint);
    try std.testing.expectEqualStrings("linearone-ngram@afae315d", c.engine);
    try std.testing.expectApproxEqAbs(@as(f64, 0.626828977), c.confidence.?, 1e-6);
    const f = router.classify(&m, std.testing.allocator, "yes");
    try std.testing.expectEqual(router.PromptHint.fast, f.hint);
    try std.testing.expectApproxEqAbs(@as(f64, 1 - 0.020501202), f.confidence.?, 1e-6);
}

// Scenario: Given no model, when classified, then the keyword rules decide
// with no confidence (unchanged default behaviour).
test "router classify without a model is the keyword router" {
    const router = opennull.router;
    const c = router.classify(null, std.testing.allocator, "show the README");
    try std.testing.expectEqual(router.PromptHint.fast, c.hint);
    try std.testing.expectEqualStrings(router.keyword_engine, c.engine);
    try std.testing.expect(c.confidence == null);
}

// Scenario: Given a valid file whose labels are not fast/powerful, when
// loaded as the router, then it is rejected (the host falls back).
test "router model must be labelled fast and powerful" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try buildFile(arena.allocator(), &.{"a1"}, 1, "");
    // buildFile writes "fast"/"powerful"; rename the first label in place.
    const at = std.mem.indexOf(u8, bytes, "fast").?;
    bytes[at] = 'l';
    try std.testing.expectError(error.UnexpectedLabels, opennull.router.RouterModel.init(std.testing.allocator, bytes));
}
