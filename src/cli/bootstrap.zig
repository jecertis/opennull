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
    /// System prompt sent with every request: either the config's explicit
    /// override or the built-in agent charter.
    system_prompt: []const u8,
    /// Heap-anchored so the transport pointers inside `provider` stay valid
    /// for the lifetime of this value.
    _http_transport: *http.HttpTransport,
    _allocator: std.mem.Allocator,
    provider: any_mod.AnyProvider,
    model: []const u8,

    pub fn deinit(self: *Bootstrapped) void {
        self.config.deinit();
        self._allocator.free(self.workspace_root);
        self._allocator.free(self.system_prompt);
        self._allocator.destroy(self._http_transport);
    }
};

/// The default charter when config.toml does not set one. Tells the model
/// what it is, where it works, and that its tools act on REAL files —
/// without this, models narrate actions instead of taking them. Pure;
/// tested in test/bootstrap_test.zig.
pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    override: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    if (override) |o| return allocator.dupe(u8, o);
    return std.fmt.allocPrint(allocator,
        \\You are opennull, a coding agent working inside a sandboxed workspace.
        \\
        \\Workspace root: {s}
        \\
        \\You have real file tools: file_read, file_write, file_edit. Use them to
        \\inspect and change actual files instead of describing what you would do.
        \\Tool paths are relative to the workspace root; requests outside it fail
        \\unless the configuration explicitly allows them. Keep replies short and
        \\concrete, and report what you actually did.
    , .{workspace_root});
}

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

    // No config.toml means zero-config defaults; other read errors are real.
    var cfg = blk: {
        if (std.Io.Dir.cwd().readFileAlloc(io, "config.toml", allocator, .limited(max_config_bytes))) |contents| {
            defer allocator.free(contents);
            break :blk try config_mod.load(allocator, contents, &dotenv_map, environ_map);
        } else |err| switch (err) {
            error.FileNotFound => break :blk try buildDefaultConfig(allocator, environ_map),
            else => return err,
        }
    };
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

    const system_prompt = try buildSystemPrompt(allocator, workspace_root, cfg.system_prompt);
    errdefer allocator.free(system_prompt);

    const t = try allocator.create(http.HttpTransport);
    t.* = .{ .allocator = allocator, .io = io };

    return .{
        .config = cfg,
        .workspace_root = workspace_root,
        .system_prompt = system_prompt,
        ._http_transport = t,
        ._allocator = allocator,
        .provider = try router.build(&cfg, selected, t.transport()),
        .model = selected.model,
    };
}

/// The config used when no config.toml exists: a fallback chain across
/// providers — whichever API key is present wins (Anthropic first), and
/// local Ollama is always available as the free last resort, so the binary
/// works out of the box with zero keys if Ollama is running. Pure; tested
/// in test/bootstrap_test.zig.
pub fn buildDefaultConfig(
    allocator: std.mem.Allocator,
    process_env: *const std.process.Environ.Map,
) config_mod.LoadError!config_mod.Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Priority order: paid-key first (existing users keep their setup),
    // then free-tier keys, then local. model ids are the long-standing
    // stable names per endpoint; override via config.toml when needed.
    const candidates = [_]struct { env: ?[]const u8, name: []const u8, kind: []const u8, base_url: []const u8, model: []const u8 }{
        .{ .env = "ANTHROPIC_API_KEY", .name = "anthropic", .kind = "anthropic", .base_url = "https://api.anthropic.com", .model = "claude-sonnet-5" },
        .{ .env = "GROQ_API_KEY", .name = "groq", .kind = "openai_compat", .base_url = "https://api.groq.com/openai/v1", .model = "qwen/qwen3.8-27b" },
        .{ .env = "GEMINI_API_KEY", .name = "gemini", .kind = "openai_compat", .base_url = "https://generativelanguage.googleapis.com/v1beta/openai", .model = "gemini-2.0-flash" },
        .{ .env = "OPENROUTER_API_KEY", .name = "openrouter", .kind = "openai_compat", .base_url = "https://openrouter.ai/api/v1", .model = "meta-llama/llama-3.3-70b-instruct:free" },
        // Always registered: free, local, no key. Ignored auth header is
        // harmless for Ollama.
        .{ .env = null, .name = "ollama", .kind = "openai_compat", .base_url = "http://localhost:11434/v1", .model = "llama3.2" },
    };

    var providers: std.ArrayListUnmanaged(config_mod.ProviderConfig) = .empty;
    var routes: std.ArrayListUnmanaged(config_mod.RouteConfig) = .empty;

    for (candidates) |c| {
        const key: []const u8 = if (c.env) |env|
            process_env.get(env) orelse continue
        else
            ""; // local servers need no auth
        try providers.append(a, .{
            .name = c.name,
            .kind = c.kind,
            .base_url = c.base_url,
            .api_key = try a.dupe(u8, key),
        });
        try routes.append(a, .{
            .hint = c.name, // e.g. hint "groq" picks groq explicitly
            .provider = c.name,
            .model = c.model,
            .tool_calling = true,
            .vision = false,
        });
    }

    return .{
        .arena = arena,
        .default_hint = routes.items[0].hint,
        .system_prompt = null,
        .providers = try providers.toOwnedSlice(a),
        .routes = try routes.toOwnedSlice(a),
        .pricing = &.{},
        .sandbox_allow = &.{},
    };
}

/// Human-readable explanation for a bootstrap error. Pure; the caller still
/// prints the underlying error tag alongside for debuggability.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no config.toml found in the current directory",
        error.MissingApiKeyEnv => "no provider is usable: export ANTHROPIC_API_KEY / GROQ_API_KEY / GEMINI_API_KEY / OPENROUTER_API_KEY (free tiers exist), or start Ollama locally (`ollama serve`), or write config.toml (see examples/config.toml)",
        error.UnknownHint => "general.default_hint names a route that does not exist in config.toml",
        error.UnknownProvider => "a route references a provider not defined under [providers]",
        error.UnknownProviderKind => "an unsupported provider kind in config.toml",
        else => "startup failed",
    };
}
