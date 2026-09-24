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
