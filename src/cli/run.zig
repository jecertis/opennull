//! `opennull run "<prompt>"` — a one-shot chat turn. `parseArgs` and
//! `extractText` are pure and fully unit-tested (test/run_test.zig);
//! `execute` is the thin, deliberately untestable seam that does real I/O
//! (reads a real env var, opens a real network connection) — see the
//! plan's manual smoke-test section.
const std = @import("std");
const provider = @import("../provider/provider.zig");
const anthropic = @import("../provider/anthropic.zig");
const http = @import("../provider/http.zig");

pub const ParsedArgs = union(enum) {
    run: struct { prompt: []const u8 },
    missing_prompt,
    unknown,
};

/// `args` excludes the program name, e.g. `["run", "fix the bug"]`.
pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len == 0) return .unknown;
    if (!std.mem.eql(u8, args[0], "run")) return .unknown;
    if (args.len < 2 or args[1].len == 0) return .missing_prompt;
    return .{ .run = .{ .prompt = args[1] } };
}

/// Concatenates every `.text` content block, skipping tool_use/tool_result
/// blocks. Caller frees the returned slice.
pub fn extractText(allocator: std.mem.Allocator, response: provider.ChatResponse) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (response.content) |block| {
        switch (block) {
            .text => |t| try buf.appendSlice(allocator, t),
            else => {},
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Hardcodes ANTHROPIC_API_KEY from the real process environment and a
/// fixed model/endpoint for this first end-to-end milestone; a full
/// config.toml + router-driven path replaces this once router.zig exists
/// (see the plan's Phase 5).
pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    prompt: []const u8,
    stdout: *std.Io.Writer,
) !void {
    const api_key = environ_map.get("ANTHROPIC_API_KEY") orelse {
        try stdout.print("error: ANTHROPIC_API_KEY is not set in the environment\n", .{});
        return;
    };

    var http_transport = http.HttpTransport{ .allocator = allocator, .io = io };
    const p = anthropic.AnthropicProvider{
        .transport = http_transport.transport(),
        .base_url = "https://api.anthropic.com",
        .api_key = api_key,
    };

    const messages = [_]provider.Message{.{
        .role = .user,
        .content = &.{.{ .text = prompt }},
    }};

    var response = p.chat(allocator, .{
        .model = "claude-sonnet-5",
        .messages = &messages,
    }) catch |err| {
        try stdout.print("error: request failed: {t}\n", .{err});
        return;
    };
    defer response.deinit();

    const text = try extractText(allocator, response);
    defer allocator.free(text);
    try stdout.print("{s}\n", .{text});
}
