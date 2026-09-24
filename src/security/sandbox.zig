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

    /// Resolves `requested_path` to an absolute path against this policy's
    /// workspace root, for a tool to actually open once it has already
    /// confirmed `isAllowed`. Does NOT itself check whether the path is
    /// allowed — callers must check that first.
    pub fn resolvePath(self: SecurityPolicy, allocator: std.mem.Allocator, requested_path: []const u8) ![]u8 {
        return resolveAgainst(allocator, self.workspace_root, requested_path);
    }

    /// Symlink-aware check for a path that already passed `isAllowed`:
    /// resolves it through the filesystem and re-applies the same rules to
    /// the real path, so a symlink inside the workspace cannot reach
    /// outside it. For a path that does not exist yet (a new file), the
    /// deepest existing ancestor is resolved and the rest appended; a
    /// dangling symlink anywhere in that missing tail is denied, since
    /// writing through it would create its target. Returns the real path
    /// to open, or null when it escapes. Caller frees.
    pub fn resolveReal(
        self: SecurityPolicy,
        allocator: std.mem.Allocator,
        io: std.Io,
        requested_path: []const u8,
    ) !?[]u8 {
        const lexical = try resolveAgainst(allocator, self.workspace_root, requested_path);
        defer allocator.free(lexical);
        const real = (try realOrDeepestAncestor(allocator, io, lexical)) orelse return null;
        errdefer allocator.free(real);

        const root = try realOrLexical(allocator, io, self.workspace_root);
        defer allocator.free(root);
        if (isWithin(root, real)) return real;
        for (self.allow) |allow_entry| {
            const lexical_allow = try resolveAgainst(allocator, self.workspace_root, allow_entry);
            defer allocator.free(lexical_allow);
            const real_allow = try realOrLexical(allocator, io, lexical_allow);
            defer allocator.free(real_allow);
            if (isWithin(real_allow, real)) return real;
        }
        allocator.free(real);
        return null;
    }
};

/// The real path of absolute `path`, or `path` itself when it does not exist
/// (an allow-list entry or test root that isn't on disk).
fn realOrLexical(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.realPathFileAbsolute(io, path, &buf) catch return allocator.dupe(u8, path);
    return allocator.dupe(u8, buf[0..n]);
}

/// Resolves absolute `path` through the filesystem. Missing trailing
/// components are re-appended to the deepest existing ancestor's real
/// path. Returns null when a missing component is a dangling symlink.
fn realOrDeepestAncestor(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var existing: []const u8 = path;
    while (true) {
        if (std.Io.Dir.realPathFileAbsolute(io, existing, &buf)) |n| {
            const tail = path[existing.len..];
            return try std.mem.concat(allocator, u8, &.{ buf[0..n], tail });
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => return err,
        }
        // A missing component that is itself a symlink points nowhere yet.
        if (std.Io.Dir.cwd().readLink(io, existing, &link_buf)) |_| return null else |_| {}
        existing = std.fs.path.dirname(existing) orelse return null;
    }
}

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
