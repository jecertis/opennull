//! Local, deterministic safety policy for the fixed built-in tool set.
const std = @import("std");

pub const Decision = enum { allow, requires_approval };

/// Reads are harmless within the existing sandbox. Every mutation is shown to
/// the user before execution; unknown names are left to registry dispatch.
pub fn decide(name: []const u8) Decision {
    if (std.mem.eql(u8, name, "file_write") or std.mem.eql(u8, name, "file_edit")) {
        return .requires_approval;
    }
    return .allow;
}
