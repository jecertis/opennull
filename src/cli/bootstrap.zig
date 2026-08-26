//! Shared CLI startup: reads the optional `.env` and the required
//! `config.toml` from the working directory, resolves provider api keys
//! (process env wins over .env), selects the route named by
//! `general.default_hint`, and constructs the concrete provider behind
//! AnyProvider. This replaces cli/run.zig's and cli/chat.zig's interim
//! hardcoded Anthropic path (the plan's Phase 5).
//!
//! `bootstrap` itself is a thin, deliberately untested seam — real file and
//! env I/O, same policy as the command execute() functions; everything it
//! composes (dotenv, toml, config.load, router.select/build) has its own
//! BDD specs. `errorMessage` IS pure and tested (test/bootstrap_test.zig).
const std = @import("std");
const config_mod = @import("../config/config.zig");
const dotenv = @import("../config/dotenv.zig");
const router = @import("../router/router.zig");
const any_mod = @import("../provider/any.zig");
const http = @import("../provider/http.zig");

/// Largest config.toml / .env we will read (1 MiB is far beyond reasonable).
const max_config_bytes: usize = 1 << 20;

pub const Error =
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.RealPathError ||
    config_mod.LoadError ||
    router.SelectError ||
    router.BuildError;

pub const Bootstrapped = struct {
    /// Owns every string referenced by provider/model/workspace_root below.
    /// Deinit last.
    config: config_mod.Config,
    /// Absolute workspace root (the process's starting directory), resolved
    /// once here so both commands share one definition of "the workspace".
    workspace_root: []const u8,
    /// Heap-anchored so the transport pointers inside `provider` stay valid
    /// for the lifetime of this value.
    _http_transport: *http.HttpTransport,
    _allocator: std.mem.Allocator,
    provider: any_mod.AnyProvider,
    model: []const u8,

    pub fn deinit(self: *Bootstrapped) void {
        self.config.deinit();
        self._allocator.free(self.workspace_root);
        self._allocator.destroy(self._http_transport);
    }
};

pub fn bootstrap(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) Error!Bootstrapped {
    // .env is optional: its absence just means fewer fallback keys.
    var dotenv_map: dotenv.Map = .{};
    defer dotenv_map.deinit(allocator);
    if (std.Io.Dir.cwd().readFileAlloc(io, ".env", allocator, .limited(max_config_bytes))) |contents| {
        defer allocator.free(contents);
        dotenv_map = try dotenv.parse(allocator, contents);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const toml_contents = try std.Io.Dir.cwd().readFileAlloc(io, "config.toml", allocator, .limited(max_config_bytes));
    defer allocator.free(toml_contents);

    var cfg = try config_mod.load(allocator, toml_contents, &dotenv_map, environ_map);
    errdefer cfg.deinit();

    // Open "." to get a real directory handle: on macOS, realPath resolves
    // via fcntl(F_GETPATH) which needs a real fd — the AT.FDCWD sentinel
    // behind Dir.cwd() would fail there.
    var workspace_dir = std.Io.Dir.cwd().openDir(io, ".", .{}) catch |err| switch (err) {
        else => return err,
    };
    defer workspace_dir.close(io);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try workspace_dir.realPath(io, &root_buf);
    const workspace_root = try allocator.dupe(u8, root_buf[0..cwd_len]);
    errdefer allocator.free(workspace_root);

    const selected = try router.select(&cfg, cfg.default_hint);

    const t = try allocator.create(http.HttpTransport);
    t.* = .{ .allocator = allocator, .io = io };

    return .{
        .config = cfg,
        .workspace_root = workspace_root,
        ._http_transport = t,
        ._allocator = allocator,
        .provider = try router.build(&cfg, selected, t.transport()),
        .model = selected.model,
    };
}

/// Human-readable explanation for a bootstrap error. Pure; the caller still
/// prints the underlying error tag alongside for debuggability.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no config.toml found in the current directory",
        error.MissingApiKeyEnv => "a configured provider's api_key_env variable is set neither in the process environment nor in .env",
        error.UnknownHint => "general.default_hint names a route that does not exist in config.toml",
        error.UnknownProvider => "a route references a provider not defined under [providers]",
        error.UnknownProviderKind => "an unsupported provider kind in config.toml",
        else => "startup failed",
    };
}
