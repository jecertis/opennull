//! BDD spec for src/config/toml.zig — a minimal TOML subset parser covering
//! only the shapes opennull's config.toml actually uses: top-level scalars,
//! `[section]` tables, dotted/nested table headers, quoted-key table
//! headers, `[[array]]` tables, and inline string arrays.
//!
//! Deferred (not in this subset, tracked for later if config.toml ever
//! needs it): multi-line strings, trailing inline comments after a value,
//! TOML datetimes, nested inline arrays/tables.
const std = @import("std");
const opennull = @import("opennull");
const toml = opennull.config.toml;

// Scenario: Given top-level string/int/float/bool assignments, when parsed,
// then each scalar is readable with its matching accessor.
test "parses simple top-level scalars" {
    var doc = try toml.parse(std.testing.allocator,
        \\name = "opennull"
        \\count = 42
        \\ratio = 3.5
        \\enabled = true
        \\
    );
    defer doc.deinit();

    try std.testing.expectEqualStrings("opennull", toml.getString(doc.root, "name").?);
    try std.testing.expectEqual(@as(i64, 42), toml.getInt(doc.root, "count").?);
    try std.testing.expectEqual(@as(f64, 3.5), toml.getFloat(doc.root, "ratio").?);
    try std.testing.expectEqual(true, toml.getBool(doc.root, "enabled").?);
}

// Scenario: Given a `[section]` header followed by keys, when parsed, then
// those keys are readable from the nested table, not the root.
test "parses a table section" {
    var doc = try toml.parse(std.testing.allocator,
        \\[general]
        \\default_hint = "default"
        \\
    );
    defer doc.deinit();

    const general = toml.getTable(doc.root, "general").?;
    try std.testing.expectEqualStrings("default", toml.getString(general, "default_hint").?);
    try std.testing.expect(toml.getString(doc.root, "default_hint") == null);
}

// Scenario: Given a dotted table header `[providers.anthropic]`, when
// parsed, then intermediate tables are created automatically and the leaf
// table holds the assigned keys.
test "parses nested dotted table header" {
    var doc = try toml.parse(std.testing.allocator,
        \\[providers.anthropic]
        \\kind = "anthropic"
        \\base_url = "https://api.anthropic.com"
        \\
    );
    defer doc.deinit();

    const providers = toml.getTable(doc.root, "providers").?;
    const anthropic = toml.getTable(providers, "anthropic").?;
    try std.testing.expectEqualStrings("anthropic", toml.getString(anthropic, "kind").?);
}

// Scenario: Given a quoted-key table header `[pricing."claude-sonnet-5"]`,
// when parsed, then the quoted segment is used verbatim (including the
// hyphens) as a single nested table key.
test "parses quoted-key table header" {
    var doc = try toml.parse(std.testing.allocator,
        \\[pricing."claude-sonnet-5"]
        \\input = 3.00
        \\output = 15.00
        \\
    );
    defer doc.deinit();

    const pricing = toml.getTable(doc.root, "pricing").?;
    const model = toml.getTable(pricing, "claude-sonnet-5").?;
    try std.testing.expectEqual(@as(f64, 3.00), toml.getFloat(model, "input").?);
    try std.testing.expectEqual(@as(f64, 15.00), toml.getFloat(model, "output").?);
}

// Scenario: Given repeated `[[routes]]` headers, when parsed, then each
// occurrence appends a new table to an array in document order.
test "parses array of tables in document order" {
    var doc = try toml.parse(std.testing.allocator,
        \\[[routes]]
        \\hint = "default"
        \\model = "claude-sonnet-5"
        \\
        \\[[routes]]
        \\hint = "cheap-fix"
        \\model = "deepseek-chat"
        \\
    );
    defer doc.deinit();

    const routes = try toml.getArrayOfTables(std.testing.allocator, doc.root, "routes");
    defer std.testing.allocator.free(routes.?);
    try std.testing.expectEqual(@as(usize, 2), routes.?.len);
    try std.testing.expectEqualStrings("default", toml.getString(routes.?[0], "hint").?);
    try std.testing.expectEqualStrings("cheap-fix", toml.getString(routes.?[1], "hint").?);
}

// Scenario: Given an inline string array `allow = ["a", "b"]`, when parsed,
// then the value is an array of string entries in order.
test "parses inline string array" {
    var doc = try toml.parse(std.testing.allocator,
        \\[sandbox]
        \\allow = ["~/.config/opennull", "/tmp/scratch"]
        \\
    );
    defer doc.deinit();

    const sandbox = toml.getTable(doc.root, "sandbox").?;
    const allow = toml.getArray(sandbox, "allow").?;
    try std.testing.expectEqual(@as(usize, 2), allow.len);
    try std.testing.expectEqualStrings("~/.config/opennull", allow[0].string);
    try std.testing.expectEqualStrings("/tmp/scratch", allow[1].string);
}

// Scenario: Given blank lines and '#' comment lines interleaved with real
// content, when parsed, then they are ignored and do not affect the result.
test "ignores blank lines and comments" {
    var doc = try toml.parse(std.testing.allocator,
        \\# top-level comment
        \\
        \\name = "opennull"
        \\# another comment
        \\
    );
    defer doc.deinit();

    try std.testing.expectEqualStrings("opennull", toml.getString(doc.root, "name").?);
}

// Scenario: Given a non-blank, non-comment, non-table-header line with no
// '=' separator, when parsed, then parsing fails with InvalidKeyValueLine
// rather than silently ignoring or misinterpreting it.
test "errors on malformed line" {
    const result = toml.parse(std.testing.allocator, "this is not valid toml\n");
    try std.testing.expectError(error.InvalidKeyValueLine, result);
}
