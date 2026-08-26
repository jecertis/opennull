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
