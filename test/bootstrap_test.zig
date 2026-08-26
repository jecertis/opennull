//! BDD spec for src/cli/bootstrap.zig's pure error-message mapping. The
//! `bootstrap()` startup seam itself (real .env/config.toml file reads,
//! env resolution, provider construction) is deliberately untested here and
//! exercised end-to-end by the manual smoke test against a local mock
//! server.
const std = @import("std");
const opennull = @import("opennull");
const bootstrap = opennull.cli.bootstrap;

// Scenario: Given a missing config.toml, when mapped, then the message
// tells the user what file is absent and where it was looked for.
test "missing config.toml maps to a message naming the file" {
    const msg = bootstrap.errorMessage(error.FileNotFound);
    try std.testing.expect(std.mem.indexOf(u8, msg, "config.toml") != null);
}

// Scenario: Given an unknown default hint, when mapped, then the message
// points at general.default_hint as the culprit.
test "unknown hint maps to a message naming default_hint" {
    const msg = bootstrap.errorMessage(error.UnknownHint);
    try std.testing.expect(std.mem.indexOf(u8, msg, "default_hint") != null);
}

// Scenario: Given any unexpected error tag, when mapped, then a generic
// but non-empty message comes back — no unreachable, no empty string.
test "unexpected errors fall back to a generic message" {
    const msg = bootstrap.errorMessage(error.ConnectionRefused);
    try std.testing.expect(msg.len > 0);
}

// -- zero-config fallback chain ------------------------------------------

fn envWith(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var m = std.process.Environ.Map.init(allocator);
    errdefer m.deinit();
    for (pairs) |kv| try m.put(kv[0], kv[1]);
    return m;
}

// Scenario: Given only ANTHROPIC_API_KEY, when the default config is built,
// then the default route goes to anthropic with the resolved key.
test "anthropic key present: default route is anthropic" {
    var penv = try envWith(std.testing.allocator, &.{.{ "ANTHROPIC_API_KEY", "sk-test" }});
    defer penv.deinit();

    var cfg = try bootstrap.buildDefaultConfig(std.testing.allocator, &penv);
    defer cfg.deinit();

    const sel = try opennull.router.select(&cfg, cfg.default_hint);
    try std.testing.expectEqualStrings("anthropic", sel.provider);
    try std.testing.expectEqualStrings("claude-sonnet-5", sel.model);
}

// Scenario: Given NO keys at all, when built, then the chain falls through
// to local Ollama — free, zero setup, works whenever ollama serve runs.
test "no keys: default route is local ollama" {
    var penv = try envWith(std.testing.allocator, &.{});
    defer penv.deinit();

    var cfg = try bootstrap.buildDefaultConfig(std.testing.allocator, &penv);
    defer cfg.deinit();

    const sel = try opennull.router.select(&cfg, cfg.default_hint);
    try std.testing.expectEqualStrings("ollama", sel.provider);

    const ollama = for (cfg.providers) |p| {
        if (std.mem.eql(u8, p.name, "ollama")) break p;
    } else unreachable;
    try std.testing.expectEqualStrings("http://localhost:11434/v1", ollama.base_url);
    try std.testing.expectEqual(@as(usize, 0), ollama.api_key.len);
}

// Scenario: Given a free-tier GROQ key (no Anthropic), when built, then the
// default route uses groq's free endpoint with its stable model id.
test "groq key present: default route is groq" {
    var penv = try envWith(std.testing.allocator, &.{.{ "GROQ_API_KEY", "gsk" }});
    defer penv.deinit();

    var cfg = try bootstrap.buildDefaultConfig(std.testing.allocator, &penv);
    defer cfg.deinit();

    const sel = try opennull.router.select(&cfg, cfg.default_hint);
    try std.testing.expectEqualStrings("groq", sel.provider);
    try std.testing.expectEqualStrings("qwen/qwen3.8-27b", sel.model);
}

// Scenario: Given BOTH an Anthropic key and a Groq key, when built, then
// priority wins: anthropic stays the default, groq remains selectable by
// its own hint without any config file.
test "priority: anthropic beats groq; hints expose both" {
    var penv = try envWith(std.testing.allocator, &.{
        .{ "ANTHROPIC_API_KEY", "sk" },
        .{ "GROQ_API_KEY", "gsk" },
    });
    defer penv.deinit();

    var cfg = try bootstrap.buildDefaultConfig(std.testing.allocator, &penv);
    defer cfg.deinit();

    const dflt = try opennull.router.select(&cfg, cfg.default_hint);
    try std.testing.expectEqualStrings("anthropic", dflt.provider);

    const groq = try opennull.router.select(&cfg, "groq");
    try std.testing.expectEqualStrings("groq", groq.provider);
    try std.testing.expectEqualStrings("qwen/qwen3.8-27b", groq.model);
}

// Scenario: Given the MissingApiKeyEnv failure (possible only via a written
// config), when mapped for display, then the message names every accepted
// free-tier variable AND the local option.
test "missing key message lists all zero-setup options" {
    const msg = bootstrap.errorMessage(error.MissingApiKeyEnv);
    try std.testing.expect(std.mem.indexOf(u8, msg, "GROQ_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "GEMINI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "OPENROUTER_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Ollama") != null);
}
