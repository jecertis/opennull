//! BDD spec for src/router/router.zig and src/provider/any.zig — runtime
//! route selection by hint and construction/dispatch of the matching
//! concrete provider. Wire-format dispatch is proven with capturing fake
//! transports: the same ChatRequest must produce Anthropic-shaped output
//! (x-api-key, /v1/messages) or OpenAI-shaped output (Bearer auth,
//! /chat/completions) depending solely on the configured kind.
const std = @import("std");
const opennull = @import("opennull");
const provider = opennull.provider.core;
const config_mod = opennull.config.config;
const router = opennull.router;

// -- fixtures ------------------------------------------------------------

const primary = config_mod.ProviderConfig{
    .name = "primary",
    .kind = "anthropic",
    .base_url = "https://api.anthropic.com",
    .api_key = "sk-primary",
};
const fallback = config_mod.ProviderConfig{
    .name = "fallback",
    .kind = "openai_compat",
    .base_url = "http://localhost:8080/v1",
    .api_key = "sk-fallback",
};

fn fixtureConfig() config_mod.Config {
    return .{
        .arena = undefined, // hand-built fixture owns static slices; never deinit'd
        .default_hint = "default",
        .system_prompt = null,
        .providers = &.{ primary, fallback },
        .routes = &.{
            .{ .hint = "default", .provider = "primary", .model = "claude-sonnet-5", .tool_calling = true, .vision = false },
            .{ .hint = "cheap", .provider = "fallback", .model = "gpt-mini", .tool_calling = true, .vision = false },
        },
        .pricing = &.{},
        .sandbox_allow = &.{},
    };
}

const CapturedRequest = struct {
    url: []u8,
    headers: []CapturedHeader,
};

/// Header with DEEP-COPIED name/value: providers build transient header
/// values (e.g. allocPrint'ed "Bearer ..." auth) that may be freed or
/// arena-reclaimed as soon as `send` returns — a shallow slice dupe would
/// leave the capture reading dangling memory.
const CapturedHeader = struct {
    name: []u8,
    value: []u8,
};

/// Records URL + headers of each send (bodies not needed for these specs).
const HeaderCaptureTransport = struct {
    requests: std.ArrayListUnmanaged(CapturedRequest) = .empty,

    fn send(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.HttpResponse {
        const self: *HeaderCaptureTransport = @ptrCast(@alignCast(ptr));
        const headers = try allocator.alloc(CapturedHeader, req.headers.len);
        for (req.headers, 0..) |h, i| {
            headers[i] = .{
                .name = try allocator.dupe(u8, h.name),
                .value = try allocator.dupe(u8, h.value),
            };
        }
        try self.requests.append(allocator, .{
            .url = try allocator.dupe(u8, req.url),
            .headers = headers,
        });
        // Each concrete provider parses its own wire shape — return the one
        // matching the endpoint this request went to.
        const body = if (std.mem.indexOf(u8, req.url, "/chat/completions") != null)
            "{\"choices\":[{\"message\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}"
        else
            "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\"}";
        return .{ .status = 200, .body = try allocator.dupe(u8, body) };
    }

    fn transport(self: *HeaderCaptureTransport) provider.Transport {
        return .{ .ptr = self, .sendFn = send };
    }
};

fn hasHeader(headers: []const CapturedHeader, name: []const u8, value_prefix: []const u8) bool {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, name) and std.mem.startsWith(u8, h.value, value_prefix)) return true;
    }
    return false;
}

// -- select --------------------------------------------------------------

// Scenario: Given a config with a "default" route, when selected by hint,
// then the route's provider name and model come back.
test "select resolves an existing hint to its provider and model" {
    const cfg = fixtureConfig();
    const sel = try router.select(&cfg, "default");
    try std.testing.expectEqualStrings("primary", sel.provider);
    try std.testing.expectEqualStrings("claude-sonnet-5", sel.model);
}

// Scenario: Given a different hint ("cheap"), when selected, then it
// resolves to a DIFFERENT provider/model pair — hints genuinely route.
test "select distinguishes between configured hints" {
    const cfg = fixtureConfig();
    const sel = try router.select(&cfg, "cheap");
    try std.testing.expectEqualStrings("fallback", sel.provider);
    try std.testing.expectEqualStrings("gpt-mini", sel.model);
}

// Scenario: Given a hint that matches no route, when selected, then it is
// an UnknownHint error — no silent misrouting.
test "select rejects an unknown hint" {
    const cfg = fixtureConfig();
    try std.testing.expectError(error.UnknownHint, router.select(&cfg, "no-such-hint"));
}

// -- build ---------------------------------------------------------------

// Scenario: Given a selection naming the anthropic-kind provider, when
// built, then the union holds the anthropic variant carrying the config's
// base_url and resolved api_key.
test "build constructs the anthropic variant from config" {
    const cfg = fixtureConfig();
    var transport_stub = HeaderCaptureTransport{};
    const p = try router.build(&cfg, .{ .provider = "primary", .model = "m" }, transport_stub.transport());

    const ap = p.anthropic;
    try std.testing.expectEqualStrings("https://api.anthropic.com", ap.base_url);
    try std.testing.expectEqualStrings("sk-primary", ap.api_key);
}

// Scenario: Given a selection naming the openai_compat-kind provider, when
// built, then the union holds the openai_compat variant with its own
// base_url/api_key.
test "build constructs the openai_compat variant from config" {
    const cfg = fixtureConfig();
    var transport_stub = HeaderCaptureTransport{};
    const p = try router.build(&cfg, .{ .provider = "fallback", .model = "m" }, transport_stub.transport());

    const op = p.openai_compat;
    try std.testing.expectEqualStrings("http://localhost:8080/v1", op.base_url);
    try std.testing.expectEqualStrings("sk-fallback", op.api_key);
}

// Scenario: Given a provider whose kind is neither supported value, when
// built, then it is an UnknownProviderKind error rather than a silent
// anthropic fallback.
test "build rejects an unsupported provider kind" {
    var cfg = fixtureConfig();
    cfg.providers = &.{.{ .name = "weird", .kind = "carrier_pigeon", .base_url = "x", .api_key = "k" }};
    var transport_stub = HeaderCaptureTransport{};
    try std.testing.expectError(
        error.UnknownProviderKind,
        router.build(&cfg, .{ .provider = "weird", .model = "m" }, transport_stub.transport()),
    );
}

// -- wire-format dispatch through AnyProvider ----------------------------

fn chatOnce(allocator: std.mem.Allocator, p: opennull.provider.any.AnyProvider) !void {
    const messages = [_]provider.Message{.{
        .role = .user,
        .content = &.{.{ .text = "hi" }},
    }};
    var resp = try p.chat(allocator, .{ .model = "m", .messages = &messages });
    defer resp.deinit();
}

// Scenario: Given an AnyProvider holding the anthropic variant, when a
// chat request is sent through the union, then the wire request is
// Anthropic-shaped: x-api-key auth header and the /v1/messages endpoint.
test "anthropic variant dispatches with x-api-key to /v1/messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = fixtureConfig();
    var capture = HeaderCaptureTransport{};
    const p = try router.build(&cfg, .{ .provider = "primary", .model = "m" }, capture.transport());

    try chatOnce(arena.allocator(), p);

    try std.testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    const req = capture.requests.items[0];
    defer {
        arena.allocator().free(req.url);
        arena.allocator().free(req.headers);
    }
    try std.testing.expect(std.mem.endsWith(u8, req.url, "/v1/messages"));
    try std.testing.expect(hasHeader(req.headers, "x-api-key", "sk-primary"));
}

// Scenario: Given the SAME call path but the openai_compat variant, when a
// chat request is sent, then the wire request is OpenAI-shaped: Bearer
// authorization header and the /chat/completions endpoint.
test "openai_compat variant dispatches with Bearer auth to /chat/completions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = fixtureConfig();
    var capture = HeaderCaptureTransport{};
    const p = try router.build(&cfg, .{ .provider = "fallback", .model = "m" }, capture.transport());

    try chatOnce(arena.allocator(), p);

    try std.testing.expectEqual(@as(usize, 1), capture.requests.items.len);
    const req = capture.requests.items[0];
    defer {
        arena.allocator().free(req.url);
        arena.allocator().free(req.headers);
    }
    try std.testing.expect(std.mem.endsWith(u8, req.url, "/chat/completions"));
    try std.testing.expect(hasHeader(req.headers, "authorization", "Bearer sk-fallback"));
}
