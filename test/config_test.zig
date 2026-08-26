//! BDD spec for src/config/config.zig — loads config.toml + resolves
//! api_key_env references against a `.env` map and a process-env map, with
//! process env taking precedence (so CI/secret managers still work).
const std = @import("std");
const opennull = @import("opennull");
const config = opennull.config.config;
const dotenv = opennull.config.dotenv;

const example_toml =
    \\[general]
    \\default_hint = "default"
    \\
    \\[providers.anthropic]
    \\kind = "anthropic"
    \\base_url = "https://api.anthropic.com"
    \\api_key_env = "ANTHROPIC_API_KEY"
    \\
    \\[[routes]]
    \\hint = "default"
    \\provider = "anthropic"
    \\model = "claude-sonnet-5"
    \\tool_calling = true
    \\vision = true
    \\
    \\[pricing."claude-sonnet-5"]
    \\input = 3.00
    \\output = 15.00
    \\
    \\[sandbox]
    \\allow = ["~/.config/opennull"]
    \\
;

fn emptyEnv(allocator: std.mem.Allocator) std.process.Environ.Map {
    return std.process.Environ.Map.init(allocator);
}

// Scenario: Given the example config with the provider's key available in
// the .env map (and no matching process env var), when loaded, then the
// provider's fields parse correctly and its api_key resolves from .env.
test "loads example config and resolves api key from dotenv" {
    var dmap = try dotenv.parse(std.testing.allocator, "ANTHROPIC_API_KEY=sk-ant-from-dotenv\n");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();

    var cfg = try config.load(std.testing.allocator, example_toml, &dmap, &penv);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("default", cfg.default_hint);
    try std.testing.expectEqual(@as(usize, 1), cfg.providers.len);
    try std.testing.expectEqualStrings("anthropic", cfg.providers[0].name);
    try std.testing.expectEqualStrings("anthropic", cfg.providers[0].kind);
    try std.testing.expectEqualStrings("https://api.anthropic.com", cfg.providers[0].base_url);
    try std.testing.expectEqualStrings("sk-ant-from-dotenv", cfg.providers[0].api_key);
}

// Scenario: Given the same env var name set in both the process env and the
// .env map with different values, when loaded, then the process env value
// wins.
test "process env takes precedence over dotenv for the same key" {
    var dmap = try dotenv.parse(std.testing.allocator, "ANTHROPIC_API_KEY=from-dotenv\n");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();
    try penv.put("ANTHROPIC_API_KEY", "from-process-env");

    var cfg = try config.load(std.testing.allocator, example_toml, &dmap, &penv);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("from-process-env", cfg.providers[0].api_key);
}

// Scenario: Given a provider whose api_key_env is present in neither the
// process env nor the .env map, when loaded, then load fails with a clear
// MissingApiKeyEnv error instead of panicking or silently leaving it blank.
test "missing api key env produces a clear error" {
    var dmap = try dotenv.parse(std.testing.allocator, "");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();

    const result = config.load(std.testing.allocator, example_toml, &dmap, &penv);
    try std.testing.expectError(error.MissingApiKeyEnv, result);
}

// Scenario: Given a route entry, when loaded, then its capability flags and
// target model/provider are parsed correctly.
test "parses route capability flags" {
    var dmap = try dotenv.parse(std.testing.allocator, "ANTHROPIC_API_KEY=x\n");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();

    var cfg = try config.load(std.testing.allocator, example_toml, &dmap, &penv);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.routes.len);
    try std.testing.expectEqualStrings("default", cfg.routes[0].hint);
    try std.testing.expectEqualStrings("anthropic", cfg.routes[0].provider);
    try std.testing.expectEqualStrings("claude-sonnet-5", cfg.routes[0].model);
    try std.testing.expectEqual(true, cfg.routes[0].tool_calling);
    try std.testing.expectEqual(true, cfg.routes[0].vision);
}

// Scenario: Given a `[pricing."<model>"]` table, when loaded, then it
// becomes a pricing entry keyed by the exact (unquoted) model name.
test "parses pricing table entries" {
    var dmap = try dotenv.parse(std.testing.allocator, "ANTHROPIC_API_KEY=x\n");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();

    var cfg = try config.load(std.testing.allocator, example_toml, &dmap, &penv);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.pricing.len);
    try std.testing.expectEqualStrings("claude-sonnet-5", cfg.pricing[0].model);
    try std.testing.expectEqual(@as(?f64, 3.00), cfg.pricing[0].input);
    try std.testing.expectEqual(@as(?f64, 15.00), cfg.pricing[0].output);
}

// Scenario: Given a `[sandbox] allow = [...]` entry, when loaded, then the
// sandbox allow list is available as a plain string slice.
test "parses sandbox allow list" {
    var dmap = try dotenv.parse(std.testing.allocator, "ANTHROPIC_API_KEY=x\n");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();

    var cfg = try config.load(std.testing.allocator, example_toml, &dmap, &penv);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.sandbox_allow.len);
    try std.testing.expectEqualStrings("~/.config/opennull", cfg.sandbox_allow[0]);
}

// Scenario: Given a route that references a provider name not present in
// [providers.*], when loaded, then load fails with UnknownProviderInRoute
// rather than the router silently having a dangling reference later.
test "route referencing an unknown provider is rejected" {
    const bad_toml =
        \\[providers.anthropic]
        \\kind = "anthropic"
        \\base_url = "https://api.anthropic.com"
        \\api_key_env = "ANTHROPIC_API_KEY"
        \\
        \\[[routes]]
        \\hint = "default"
        \\provider = "does-not-exist"
        \\model = "claude-sonnet-5"
        \\tool_calling = true
        \\
    ;
    var dmap = try dotenv.parse(std.testing.allocator, "ANTHROPIC_API_KEY=x\n");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();

    const result = config.load(std.testing.allocator, bad_toml, &dmap, &penv);
    try std.testing.expectError(error.UnknownProviderInRoute, result);
}

// Scenario: Given [general] with a system_prompt string, when loaded, then
// it surfaces on the config for the bootstrap layer to use.
test "parses an optional system_prompt from general" {
    var dmap = try dotenv.parse(std.testing.allocator, "");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();

    const standalone =
        \\[general]
        \\default_hint = "default"
        \\system_prompt = "custom charter"
        \\
    ;
    var cfg = try config.load(std.testing.allocator, standalone, &dmap, &penv);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("custom charter", cfg.system_prompt.?);
}

// Scenario: Given a config without system_prompt, when loaded, then the
// field is null (the caller's built-in charter applies).
test "absent system_prompt loads as null" {
    var dmap = try dotenv.parse(std.testing.allocator, "ANTHROPIC_API_KEY=sk-ant-from-dotenv\n");
    defer dmap.deinit(std.testing.allocator);
    var penv = emptyEnv(std.testing.allocator);
    defer penv.deinit();

    var cfg = try config.load(std.testing.allocator, example_toml, &dmap, &penv);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.system_prompt);
}
