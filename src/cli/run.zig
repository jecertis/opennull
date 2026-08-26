//! `opennull run "<prompt>"` — a one-shot chat turn. `parseArgs` and
//! `extractText` are pure and fully unit-tested (test/run_test.zig);
//! `execute` is the thin, deliberately untestable seam that does real I/O
//! (boots config.toml via cli/bootstrap, opens a real network connection).
const std = @import("std");
const provider = @import("../provider/provider.zig");
const bootstrap = @import("bootstrap.zig");

pub const ParsedArgs = union(enum) {
    run: struct { prompt: []const u8 },
    chat,
    missing_prompt,
    unknown,
};

/// `args` excludes the program name, e.g. `["run", "fix the bug"]`.
pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len == 0) return .unknown;
    if (std.mem.eql(u8, args[0], "chat")) {
        if (args.len > 1) return .unknown;
        return .chat;
    }
    if (!std.mem.eql(u8, args[0], "run")) return .unknown;
    if (args.len < 2 or args[1].len == 0) return .missing_prompt;
    return .{ .run = .{ .prompt = args[1] } };
}

/// Reply-text extraction moved to provider.extractText so the chat session
/// and future TUI share one implementation.
pub const extractText = provider.extractText;

/// Boots the router-driven path (config.toml + .env + default hint) and
/// sends the prompt as a single-turn chat through whichever provider the
/// route selects.
pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    prompt: []const u8,
    stdout: *std.Io.Writer,
) !void {
    var boot = bootstrap.bootstrap(allocator, io, environ_map) catch |err| {
        try stdout.print("error: {s} ({t})\n", .{ bootstrap.errorMessage(err), err });
        return;
    };
    defer boot.deinit();

    const messages = [_]provider.Message{.{
        .role = .user,
        .content = &.{.{ .text = prompt }},
    }};

    var response = boot.provider.chat(allocator, .{
        .model = boot.model,
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
