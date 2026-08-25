//! BDD spec for src/config/dotenv.zig — parses a `.env` file into a map of
//! secret env var names to values, used to resolve `api_key_env` references
//! from config.toml without ever putting secret values in tracked config.
const std = @import("std");
const opennull = @import("opennull");
const dotenv = opennull.config.dotenv;

// Scenario: Given a simple KEY=VALUE line, when parsed, then the map
// contains that key mapped to that value.
test "parses a simple key=value line" {
    var map = try dotenv.parse(std.testing.allocator, "ANTHROPIC_API_KEY=sk-ant-123\n");
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sk-ant-123", map.get("ANTHROPIC_API_KEY").?);
}

// Scenario: Given blank lines and comment lines starting with '#', when
// parsed, then they are ignored and do not produce entries or errors.
test "ignores blank lines and comments" {
    var map = try dotenv.parse(std.testing.allocator,
        \\# this is a comment
        \\
        \\OPENAI_API_KEY=sk-openai-456
        \\
    );
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), map.count());
    try std.testing.expectEqualStrings("sk-openai-456", map.get("OPENAI_API_KEY").?);
}

// Scenario: Given a value wrapped in double quotes, when parsed, then the
// surrounding quotes are stripped from the stored value.
test "strips surrounding double quotes from value" {
    var map = try dotenv.parse(std.testing.allocator, "KEY=\"quoted value\"\n");
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("quoted value", map.get("KEY").?);
}

// Scenario: Given the same key defined twice, when parsed, then the later
// definition wins.
test "later duplicate key overrides earlier one" {
    var map = try dotenv.parse(std.testing.allocator,
        \\KEY=first
        \\KEY=second
        \\
    );
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", map.get("KEY").?);
}

// Scenario: Given surrounding whitespace around the key and value, when
// parsed, then the whitespace is trimmed.
test "trims whitespace around key and value" {
    var map = try dotenv.parse(std.testing.allocator, "  KEY  =   value with spaces  \n");
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("value with spaces", map.get("KEY").?);
}

// Scenario: Given a line with no '=' separator, when parsed, then that line
// is skipped rather than causing an error (malformed lines are tolerated,
// not fatal).
test "skips malformed line with no separator" {
    var map = try dotenv.parse(std.testing.allocator,
        \\not a valid line
        \\KEY=value
        \\
    );
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), map.count());
}
