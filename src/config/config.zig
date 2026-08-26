//! Typed config loaded from config.toml, with api_key_env references
//! resolved against a process-env map (highest precedence) and a .env map
//! (fallback). See test/config_test.zig for scenarios.
const std = @import("std");
const toml = @import("toml.zig");
const dotenv = @import("dotenv.zig");

pub const ProviderConfig = struct {
    name: []const u8,
    kind: []const u8,
    base_url: []const u8,
    api_key: []const u8,
};

pub const RouteConfig = struct {
    hint: []const u8,
    provider: []const u8,
    model: []const u8,
    tool_calling: bool,
    vision: bool,
};

pub const PriceEntry = struct {
    model: []const u8,
    input: ?f64,
    output: ?f64,
    flat: ?f64,
};

pub const LoadError = error{
    MissingApiKeyEnv,
    UnknownProviderInRoute,
    MissingField,
} || toml.ParseError || std.mem.Allocator.Error;

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    default_hint: []const u8,
    /// Optional [general] system_prompt override; null means the caller's
    /// built-in default charter applies.
    system_prompt: ?[]const u8,
    providers: []const ProviderConfig,
    routes: []const RouteConfig,
    pricing: []const PriceEntry,
    sandbox_allow: []const []const u8,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub fn load(
    child_allocator: std.mem.Allocator,
    toml_contents: []const u8,
    dotenv_map: *const dotenv.Map,
    process_env: *const std.process.Environ.Map,
) LoadError!Config {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var doc = try toml.parse(child_allocator, toml_contents);
    defer doc.deinit();

    const default_hint = blk: {
        const general = toml.getTable(doc.root, "general");
        const raw = if (general) |g| (toml.getString(g, "default_hint") orelse "default") else "default";
        break :blk try a.dupe(u8, raw);
    };

    const system_prompt = blk: {
        const general = toml.getTable(doc.root, "general");
        const raw = if (general) |g| toml.getString(g, "system_prompt") else null;
        break :blk if (raw) |r| try a.dupe(u8, r) else null;
    };

    const providers = try loadProviders(a, doc.root, dotenv_map, process_env);
    const routes = try loadRoutes(a, doc.root);
    try validateRoutes(routes, providers);
    const pricing = try loadPricing(a, doc.root);
    const sandbox_allow = try loadSandboxAllow(a, doc.root);

    return Config{
        .arena = arena,
        .default_hint = default_hint,
        .system_prompt = system_prompt,
        .providers = providers,
        .routes = routes,
        .pricing = pricing,
        .sandbox_allow = sandbox_allow,
    };
}

fn loadProviders(
    a: std.mem.Allocator,
    root: *toml.Table,
    dotenv_map: *const dotenv.Map,
    process_env: *const std.process.Environ.Map,
) LoadError![]const ProviderConfig {
    var out: std.ArrayListUnmanaged(ProviderConfig) = .empty;
    const providers_table = toml.getTable(root, "providers") orelse return out.toOwnedSlice(a);

    var it = providers_table.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const provider_table = switch (entry.value_ptr.*.*) {
            .table => |t| t,
            else => continue,
        };
        const kind = toml.getString(provider_table, "kind") orelse return error.MissingField;
        const base_url = toml.getString(provider_table, "base_url") orelse return error.MissingField;
        const api_key_env = toml.getString(provider_table, "api_key_env") orelse return error.MissingField;

        const api_key = process_env.get(api_key_env) orelse
            dotenv_map.get(api_key_env) orelse
            return error.MissingApiKeyEnv;

        try out.append(a, .{
            .name = try a.dupe(u8, name),
            .kind = try a.dupe(u8, kind),
            .base_url = try a.dupe(u8, base_url),
            .api_key = try a.dupe(u8, api_key),
        });
    }
    return out.toOwnedSlice(a);
}

fn loadRoutes(a: std.mem.Allocator, root: *toml.Table) LoadError![]const RouteConfig {
    var out: std.ArrayListUnmanaged(RouteConfig) = .empty;
    const tables = (try toml.getArrayOfTables(a, root, "routes")) orelse return out.toOwnedSlice(a);
    defer a.free(tables);

    for (tables) |t| {
        const hint = toml.getString(t, "hint") orelse return error.MissingField;
        const provider = toml.getString(t, "provider") orelse return error.MissingField;
        const model = toml.getString(t, "model") orelse return error.MissingField;
        const tool_calling = toml.getBool(t, "tool_calling") orelse false;
        const vision = toml.getBool(t, "vision") orelse false;

        try out.append(a, .{
            .hint = try a.dupe(u8, hint),
            .provider = try a.dupe(u8, provider),
            .model = try a.dupe(u8, model),
            .tool_calling = tool_calling,
            .vision = vision,
        });
    }
    return out.toOwnedSlice(a);
}

fn validateRoutes(routes: []const RouteConfig, providers: []const ProviderConfig) LoadError!void {
    for (routes) |route| {
        var found = false;
        for (providers) |p| {
            if (std.mem.eql(u8, p.name, route.provider)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownProviderInRoute;
    }
}

fn loadPricing(a: std.mem.Allocator, root: *toml.Table) LoadError![]const PriceEntry {
    var out: std.ArrayListUnmanaged(PriceEntry) = .empty;
    const pricing_table = toml.getTable(root, "pricing") orelse return out.toOwnedSlice(a);

    var it = pricing_table.iterator();
    while (it.next()) |entry| {
        const model_table = switch (entry.value_ptr.*.*) {
            .table => |t| t,
            else => continue,
        };
        try out.append(a, .{
            .model = try a.dupe(u8, entry.key_ptr.*),
            .input = toml.getFloat(model_table, "input"),
            .output = toml.getFloat(model_table, "output"),
            .flat = toml.getFloat(model_table, "flat"),
        });
    }
    return out.toOwnedSlice(a);
}

fn loadSandboxAllow(a: std.mem.Allocator, root: *toml.Table) LoadError![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const sandbox_table = toml.getTable(root, "sandbox") orelse return out.toOwnedSlice(a);
    const arr = toml.getArray(sandbox_table, "allow") orelse return out.toOwnedSlice(a);

    for (arr) |v| {
        switch (v.*) {
            .string => |s| try out.append(a, try a.dupe(u8, s)),
            else => {},
        }
    }
    return out.toOwnedSlice(a);
}
