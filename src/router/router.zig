//! The router: picks a route (provider + model) by hint from the typed
//! config, and constructs the matching concrete provider behind AnyProvider.
//! This is what replaces cli/run.zig's and cli/chat.zig's interim hardcoded
//! Anthropic path. Route→provider references are already validated when the
//! config loads (config.validateRoutes); build() still defends against a
//! hand-assembled Config with an unknown kind. See test/router_test.zig.
const std = @import("std");
const config_mod = @import("../config/config.zig");
const provider = @import("../provider/provider.zig");
const any = @import("../provider/any.zig");
const policy = @import("policy.zig");
const ngram = @import("ngram.zig");
const version = @import("../root.zig").version;

pub const Config = config_mod.Config;

pub const SelectError = error{UnknownHint};

/// The route outcome: which configured provider to use and with which model.
pub const Selected = struct {
    provider: []const u8,
    model: []const u8,
};

/// Exact-match lookup of `hint` among the configured routes. Hints are an
/// intentional closed vocabulary from config.toml — there is no implicit
/// fallback, so a typo fails loudly instead of silently misrouting.
pub fn select(cfg: *const Config, hint: []const u8) SelectError!Selected {
    for (cfg.routes) |route| {
        if (std.mem.eql(u8, route.hint, hint)) {
            return .{ .provider = route.provider, .model = route.model };
        }
    }
    return error.UnknownHint;
}

/// Selects the route for one user prompt. A configured harness hint is used
/// only when it resolves; otherwise general.default_hint remains the safe,
/// backwards-compatible fallback.
pub fn selectForPrompt(cfg: *const Config, prompt: []const u8) Selected {
    return selectForHint(cfg, policy.classifyPrompt(prompt));
}

/// The route for an already-decided hint, e.g. a user's /fast or /powerful
/// override. Same fallback to general.default_hint as selectForPrompt.
pub fn selectForHint(cfg: *const Config, hint: policy.Hint) Selected {
    const configured = switch (hint) {
        .fast => cfg.harness.fast_hint,
        .powerful => cfg.harness.powerful_hint,
    } orelse cfg.default_hint;
    return select(cfg, configured) catch select(cfg, cfg.default_hint) catch unreachable;
}

pub const classifyPrompt = policy.classifyPrompt;
pub const PromptHint = policy.Hint;

pub const keyword_engine = "opennull-keyword@" ++ version;

/// A validated LinearOne n-gram model whose labels are exactly fast and
/// powerful (in either order).
pub const RouterModel = struct {
    model: ngram.Model,
    /// Which of the model's two labels means `fast`.
    fast_index: u1,

    pub const LoadError = ngram.ParseError || error{UnexpectedLabels};

    /// `bytes` must outlive the returned value.
    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) LoadError!RouterModel {
        var model = try ngram.parse(allocator, bytes);
        errdefer model.deinit(allocator);
        const l = model.labels;
        const fast_index: u1 = if (std.mem.eql(u8, l[0], "fast") and std.mem.eql(u8, l[1], "powerful"))
            0
        else if (std.mem.eql(u8, l[1], "fast") and std.mem.eql(u8, l[0], "powerful"))
            1
        else
            return error.UnexpectedLabels;
        return .{ .model = model, .fast_index = fast_index };
    }

    pub fn deinit(self: *RouterModel, allocator: std.mem.Allocator) void {
        self.model.deinit(allocator);
    }
};

/// A routing decision plus what made it, for the event log.
pub const Classified = struct {
    hint: PromptHint,
    engine: []const u8,
    /// Probability of `hint`; null for the keyword rules.
    confidence: ?f64,
};

/// Routes with the model when one is loaded, else the keyword rules. A
/// scoring failure (out of memory) also falls back rather than failing.
pub fn classify(model: ?*const RouterModel, allocator: std.mem.Allocator, prompt: []const u8) Classified {
    if (model) |m| {
        if (ngram.score(&m.model, allocator, prompt)) |s| {
            return .{
                .hint = if (s.label == m.fast_index) .fast else .powerful,
                .engine = m.model.engine(),
                .confidence = s.confidence(),
            };
        } else |_| {}
    }
    return .{ .hint = policy.classifyPrompt(prompt), .engine = keyword_engine, .confidence = null };
}

pub const BuildError = error{ UnknownProviderKind, UnknownProvider };

/// Constructs the concrete provider named by `selected`, resolving its
/// base_url/api_key from the same (already-loaded) config.
pub fn build(
    cfg: *const Config,
    selected: Selected,
    transport: provider.Transport,
) BuildError!any.AnyProvider {
    for (cfg.providers) |p| {
        if (!std.mem.eql(u8, p.name, selected.provider)) continue;

        if (std.mem.eql(u8, p.kind, "anthropic")) {
            return .{ .anthropic = .{
                .transport = transport,
                .base_url = p.base_url,
                .api_key = p.api_key,
            } };
        }
        if (std.mem.eql(u8, p.kind, "openai_compat")) {
            return .{ .openai_compat = .{
                .transport = transport,
                .base_url = p.base_url,
                .api_key = p.api_key,
            } };
        }
        return error.UnknownProviderKind;
    }
    return error.UnknownProvider;
}
