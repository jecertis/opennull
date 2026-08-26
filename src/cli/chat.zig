//! `opennull chat` — an interactive multi-turn REPL on top of the agent
//! session. `parseLine` and the tool-activity formatters are pure and fully
//! unit-tested (test/chat_test.zig); `execute` is the thin, deliberately
//! untestable seam doing real stdin/stdout/network I/O (provider comes from
//! cli/bootstrap's config.toml-driven path).
const std = @import("std");
const loop = @import("../agent/loop.zig");
const sandbox = @import("../security/sandbox.zig");
const session = @import("../agent/session.zig");
const bootstrap = @import("bootstrap.zig");

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

/// "[tool] file_read {\"path\":\"a.txt\"}" — the tool's name plus its
/// compact JSON input. Caller frees.
pub fn formatToolStarted(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: std.json.Value,
) ![]u8 {
    const input_json = try std.json.Stringify.valueAlloc(allocator, input, .{});
    defer allocator.free(input_json);
    return std.fmt.allocPrint(allocator, "[tool] {s} {s}", .{ name, input_json });
}

/// "[tool] file_read ok" on success; on failure only the FIRST line of the
/// detail is shown (details can be whole file contents or stack-ish text).
/// Caller frees.
pub fn formatToolFinished(
    allocator: std.mem.Allocator,
    name: []const u8,
    ok: bool,
    detail: []const u8,
) ![]u8 {
    if (ok) return std.fmt.allocPrint(allocator, "[tool] {s} ok", .{name});
    const first_line_len = std.mem.indexOfScalar(u8, detail, '\n') orelse detail.len;
    return std.fmt.allocPrint(allocator, "[tool] {s} failed: {s}", .{ name, detail[0..first_line_len] });
}

/// Prints tool activity to the REPL's stdout as it happens. Best-effort:
/// notify never fails and swallows write errors (losing an activity line
/// must not abort the agent turn).
const StdoutReporter = struct {
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,

    fn reporter(self: *StdoutReporter) loop.Reporter {
        return .{ .ptr = self, .notifyFn = notify };
    }

    fn notify(ptr: *anyopaque, activity: loop.ToolActivity) void {
        const self: *StdoutReporter = @ptrCast(@alignCast(ptr));
        self.print(activity) catch {};
    }

    fn print(self: *StdoutReporter, activity: loop.ToolActivity) !void {
        const line = switch (activity) {
            .started => |e| try formatToolStarted(self.allocator, e.name, e.input),
            .finished => |e| try formatToolFinished(self.allocator, e.name, e.ok, e.detail),
        };
        defer self.allocator.free(line);
        try self.w.print("{s}\n", .{line});
        self.w.flush() catch {}; // show activity immediately, even mid-turn
    }
};

/// Reads lines from stdin until EOF or /exit, running a full agent turn
/// per prompt with the whole-session history retained. One arena backs the
/// entire session and reclaims everything on exit.
pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
) !void {
    var boot = bootstrap.bootstrap(allocator, io, environ_map) catch |err| {
        try stdout.print("error: {s} ({t})\n", .{ bootstrap.errorMessage(err), err });
        return;
    };
    defer boot.deinit();

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

    var activity_reporter = StdoutReporter{ .allocator = allocator, .w = stdout };

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
                    boot.provider,
                    &policy,
                    &history,
                    boot.model,
                    text,
                    activity_reporter.reporter(),
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
