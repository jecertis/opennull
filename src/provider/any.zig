//! Runtime provider selection: a closed-set tagged union over the concrete
//! providers (same philosophy as tools/tool.zig — exhaustiveness checking,
//! no indirect calls) so the router can hand the agent loop a provider
//! chosen at runtime from config.toml while `chat()` stays a plain static
//! dispatch. See test/router_test.zig.
const std = @import("std");
const provider = @import("provider.zig");
const anthropic = @import("anthropic.zig");
const openai_compat = @import("openai_compat.zig");

pub const AnyProvider = union(enum) {
    anthropic: anthropic.AnthropicProvider,
    openai_compat: openai_compat.OpenAiCompatProvider,

    /// Provider-neutral chat: dispatches to whichever concrete provider
    /// this holds. Allocation/ownership semantics are those of the concrete
    /// `chat` (returned ChatResponse owns its parsed-JSON arena via `_raw`).
    pub fn chat(self: AnyProvider, allocator: std.mem.Allocator, req: provider.ChatRequest) !provider.ChatResponse {
        return switch (self) {
            inline else => |p| p.chat(allocator, req),
        };
    }
};
