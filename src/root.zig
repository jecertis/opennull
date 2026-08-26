//! opennull library root — re-exports submodules used by main.zig and by
//! the test executables under test/.
const std = @import("std");

pub const security = @import("security/sandbox.zig");
pub const config = struct {
    pub const dotenv = @import("config/dotenv.zig");
    pub const toml = @import("config/toml.zig");
    pub const config = @import("config/config.zig");
};
pub const provider = struct {
    pub const core = @import("provider/provider.zig");
    pub const anthropic = @import("provider/anthropic.zig");
    pub const openai_compat = @import("provider/openai_compat.zig");
    pub const any = @import("provider/any.zig");
    pub const http = @import("provider/http.zig");
    pub const sse = @import("provider/sse.zig");
};
pub const router = @import("router/router.zig");
pub const cli = struct {
    pub const run = @import("cli/run.zig");
    pub const chat = @import("cli/chat.zig");
    pub const bootstrap = @import("cli/bootstrap.zig");
    pub const display = @import("cli/display.zig");
    pub const upgrade = @import("cli/upgrade.zig");
};
pub const tools = struct {
    pub const tool = @import("tools/tool.zig");
    pub const registry = @import("tools/registry.zig");
};
pub const agent = struct {
    pub const loop = @import("agent/loop.zig");
    pub const session = @import("agent/session.zig");
    pub const usage = @import("agent/usage.zig");
};

pub const version = "0.1.2";

test {
    std.testing.refAllDecls(@This());
}
