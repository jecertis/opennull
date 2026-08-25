//! Workspace-scoped filesystem sandbox. Every tool that touches a path must
//! go through `SecurityPolicy.isAllowed` before doing any I/O. See
//! test/sandbox_test.zig for the BDD scenarios this implements.
const std = @import("std");

pub const SecurityPolicy = struct {
    /// Absolute path to the workspace root, no trailing separator.
    workspace_root: []const u8,
    /// Additional absolute paths (or path prefixes) allowed outside the
    /// workspace root, e.g. a config directory.
    allow: []const []const u8 = &.{},

    pub fn isAllowed(
        self: SecurityPolicy,
        allocator: std.mem.Allocator,
        requested_path: []const u8,
    ) !bool {
        const resolved = try resolveAgainst(allocator, self.workspace_root, requested_path);
        defer allocator.free(resolved);

        if (isWithin(self.workspace_root, resolved)) return true;

        for (self.allow) |allow_entry| {
            const resolved_allow = try resolveAgainst(allocator, self.workspace_root, allow_entry);
            defer allocator.free(resolved_allow);
            if (isWithin(resolved_allow, resolved)) return true;
        }

        return false;
    }
};

/// Lexically resolve `path` to an absolute path: if already absolute it is
/// just normalized (".." / "." segments collapsed); if relative it is joined
/// onto `base` first. Purely lexical — does not touch the filesystem, so it
/// does not follow symlinks (see the deferred scenario in
/// test/sandbox_test.zig).
fn resolveAgainst(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(allocator, &.{path});
    }
    return std.fs.path.resolve(allocator, &.{ base, path });
}

/// True when `candidate` is `root` itself or a path segment beneath it.
/// Compares on path-segment boundaries so a sibling directory that merely
/// shares a string prefix (e.g. "/workspace-evil" vs root "/workspace")
/// does not falsely match.
fn isWithin(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (candidate.len <= root.len) return false;
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    return candidate[root.len] == std.fs.path.sep;
}
