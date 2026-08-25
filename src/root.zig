//! opennull library root — re-exports submodules used by main.zig and by
//! the test executables under test/.
const std = @import("std");

pub const security = @import("security/sandbox.zig");
pub const config = struct {
    pub const dotenv = @import("config/dotenv.zig");
};

pub const version = "0.1.0";

test {
    std.testing.refAllDecls(@This());
}
