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
    pub const http = @import("provider/http.zig");
};
pub const cli = struct {
    pub const run = @import("cli/run.zig");
};

pub const version = "0.1.0";

test {
    std.testing.refAllDecls(@This());
}
