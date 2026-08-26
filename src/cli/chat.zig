//! `opennull chat` — an interactive multi-turn REPL on top of the agent
//! session. `parseLine` is pure and fully unit-tested (test/chat_test.zig);
//! `execute` is the thin, deliberately untestable seam doing real stdin/
//! stdout/network I/O — same pattern as cli/run.zig's `execute`.
const std = @import("std");
const provider = @import("../provider/provider.zig");
const anthropic = @import("../provider/anthropic.zig");
const http = @import("../provider/http.zig");
const sandbox = @import("../security/sandbox.zig");
const session = @import("../agent/session.zig");

/// Fixed model/endpoint until the router-driven path lands (Phase 5),
/// matching cli/run.zig's interim hardcode.
const default_model = "claude-sonnet-5";

pub const ParsedLine = union(enum) {
    /// Empty or whitespace-only input: ignore without an API call.
    skip,
    /// Explicit quit command.
    exit,
    /// Any other non-empty line is a user prompt (trimmed).
    prompt: []const u8,
};

/// Classifies one raw line read from stdin (no trailing newline).
pub fn parseLine(raw: []const u8) ParsedLine {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0) return .skip;
    if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return .exit;
    return .{ .prompt = line };
}

/// Reads lines from stdin until EOF or /exit, running a full agent turn
/// per prompt with the whole-session history retained. One arena backs the
/// entire session and reclaims everything on exit.
pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
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

    // Open "." to get a real directory handle: on macOS, realPath resolves
    // via fcntl(F_GETPATH) which needs a real fd — the AT.FDCWD sentinel
    // behind Dir.cwd() would fail there.
    var workspace_dir = std.Io.Dir.cwd().openDir(io, ".", .{}) catch |err| {
        try stdout.print("error: cannot open workspace root: {t}\n", .{err});
        return;
    };
    defer workspace_dir.close(io);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = workspace_dir.realPath(io, &root_buf) catch |err| {
        try stdout.print("error: cannot resolve workspace root: {t}\n", .{err});
        return;
    };
    const policy = sandbox.SecurityPolicy{ .workspace_root = root_buf[0..cwd_len] };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var history: session.History = .empty;

    try stdout.print(
        "opennull chat — tools enabled, workspace: {s}\n" ++
            "type a prompt, /exit to quit\n",
        .{policy.workspace_root},
    );

    var stdin_buffer: [16384]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    while (true) {
        try stdout.print("you> ", .{});
        try stdout.flush();

        // null only on clean EOF before any bytes (Ctrl-D) — our exit.
        const raw_line = stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stdout.print("error: line exceeds {d}-byte input buffer; exiting\n", .{stdin_buffer.len});
                break;
            },
            else => return err,
        } orelse break;

        switch (parseLine(raw_line)) {
            .skip => continue,
            .exit => break,
            .prompt => |text| {
                const reply = session.sendPrompt(
                    arena.allocator(),
                    io,
                    p,
                    &policy,
                    &history,
                    default_model,
                    text,
                ) catch |err| {
                    // Stay in the session: a failed request must not lose
                    // the conversation already accumulated.
                    try stdout.print("error: request failed: {t}\n", .{err});
                    continue;
                };
                try stdout.print("assistant> {s}\n", .{reply});
            },
        }
    }
}
