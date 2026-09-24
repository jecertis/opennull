//! BDD spec for src/security/sandbox.zig — the workspace-scoped allowlist
//! that every filesystem/shell tool must be checked against before touching
//! a path. A bug here is a sandbox escape, so every scenario is written and
//! run red before any implementation exists.
//!
//! Lexical scenarios come first; the symlink scenarios at the end run
//! `resolveReal` against real temporary directories.

const std = @import("std");
const opennull = @import("opennull");
const SecurityPolicy = opennull.security.SecurityPolicy;

// Scenario: Given a relative path that stays inside the workspace root,
// when checking isAllowed, then it is allowed.
test "relative path inside workspace is allowed" {
    const policy = SecurityPolicy{ .workspace_root = "/workspace" };
    const allowed = try policy.isAllowed(std.testing.allocator, "src/main.zig");
    try std.testing.expect(allowed);
}

// Scenario: Given a relative path containing ".." that escapes the
// workspace root, when checking isAllowed, then it is rejected.
test "relative path escaping workspace via .. is rejected" {
    const policy = SecurityPolicy{ .workspace_root = "/workspace" };
    const allowed = try policy.isAllowed(std.testing.allocator, "../etc/passwd");
    try std.testing.expect(!allowed);
}

// Scenario: Given an absolute path inside the workspace root, when checking
// isAllowed, then it is allowed.
test "absolute path inside workspace is allowed" {
    const policy = SecurityPolicy{ .workspace_root = "/workspace" };
    const allowed = try policy.isAllowed(std.testing.allocator, "/workspace/src/main.zig");
    try std.testing.expect(allowed);
}

// Scenario: Given the workspace root path itself, when checking isAllowed,
// then it is allowed (the root is always inside itself).
test "workspace root itself is allowed" {
    const policy = SecurityPolicy{ .workspace_root = "/workspace" };
    const allowed = try policy.isAllowed(std.testing.allocator, "/workspace");
    try std.testing.expect(allowed);
}

// Scenario: Given an absolute path outside the workspace and not present in
// the allow list, when checking isAllowed, then it is rejected.
test "absolute path outside workspace with no allow entry is rejected" {
    const policy = SecurityPolicy{ .workspace_root = "/workspace" };
    const allowed = try policy.isAllowed(std.testing.allocator, "/etc/hosts");
    try std.testing.expect(!allowed);
}

// Scenario: Given a path that merely shares a string prefix with the
// workspace root but is actually a sibling directory (e.g. "/workspace-evil"
// vs root "/workspace"), when checking isAllowed, then it is rejected —
// prefix matching must respect path-segment boundaries, not raw byte prefix.
test "sibling directory sharing a string prefix is rejected" {
    const policy = SecurityPolicy{ .workspace_root = "/workspace" };
    const allowed = try policy.isAllowed(std.testing.allocator, "/workspace-evil/secret.txt");
    try std.testing.expect(!allowed);
}

// Scenario: Given an absolute path outside the workspace that IS present in
// the configured allow list, when checking isAllowed, then it is allowed.
test "absolute path outside workspace but in allow list is allowed" {
    const policy = SecurityPolicy{
        .workspace_root = "/workspace",
        .allow = &.{"/home/user/.config/opennull"},
    };
    const allowed = try policy.isAllowed(
        std.testing.allocator,
        "/home/user/.config/opennull/keys.txt",
    );
    try std.testing.expect(allowed);
}

// Scenario: Given an absolute path outside the workspace and NOT covered by
// any allow-list entry, when checking isAllowed, then it is rejected even
// though other allow entries exist.
// Scenario: Given a relative path, when resolved (not just allow-checked),
// then the returned path is the absolute, lexically-normalized form joined
// onto the workspace root — so a tool that already called isAllowed can
// actually open the file without re-implementing path joining.
test "resolvePath returns the absolute form of a relative path" {
    const policy = SecurityPolicy{ .workspace_root = "/workspace" };
    const resolved = try policy.resolvePath(std.testing.allocator, "src/main.zig");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("/workspace/src/main.zig", resolved);
}

// Scenario: Given an already-absolute path, when resolved, then it is
// returned normalized (".." collapsed) rather than joined onto the root.
test "resolvePath normalizes an already-absolute path" {
    const policy = SecurityPolicy{ .workspace_root = "/workspace" };
    const resolved = try policy.resolvePath(std.testing.allocator, "/workspace/./src/../src/main.zig");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("/workspace/src/main.zig", resolved);
}

test "absolute path outside workspace and outside all allow entries is rejected" {
    const policy = SecurityPolicy{
        .workspace_root = "/workspace",
        .allow = &.{"/home/user/.config/opennull"},
    };
    const allowed = try policy.isAllowed(std.testing.allocator, "/etc/hosts");
    try std.testing.expect(!allowed);
}

// Scenario: Given an ABSOLUTE allow entry, when the requested path lies
// beneath it, then access is granted despite being outside the workspace.
test "path beneath an absolute allow entry is allowed" {
    const policy = SecurityPolicy{
        .workspace_root = "/workspace",
        .allow = &.{"/home/user/.config/opennull"},
    };
    const allowed = try policy.isAllowed(std.testing.allocator, "/home/user/.config/opennull/config.toml");
    try std.testing.expect(allowed);
}

// Scenario: Given a RELATIVE allow entry, when checked, then it resolves
// against the workspace root first — config authors write sibling
// directories as "../name", not absolute paths. Access is granted beneath
// the resolved directory but NOT beside it.
test "relative allow entry grants access beneath its resolved directory" {
    const policy = SecurityPolicy{
        .workspace_root = "/work/ws",
        .allow = &.{"../shared-notes"},
    };
    // "/work/shared-notes/plan.md" — outside the root, beneath the entry.
    const allowed = try policy.isAllowed(std.testing.allocator, "../shared-notes/plan.md");
    try std.testing.expect(allowed);
    // But a file merely NEXT to that directory is still denied.
    const denied = try policy.isAllowed(std.testing.allocator, "../shared-notes-secret.txt");
    try std.testing.expect(!denied);
}

// Scenario: Given an allow entry, when the requested path shares only a
// string prefix with it (sibling dir "...-evil"), then access stays denied
// — segment-boundary matching must hold for allow entries too.
test "sibling prefix of an allow entry does not match" {
    const policy = SecurityPolicy{
        .workspace_root = "/work/ws",
        .allow = &.{"/work/shared"},
    };
    const denied = try policy.isAllowed(std.testing.allocator, "/work/shared-evil/x.txt");
    try std.testing.expect(!denied);
}

// -- symlinks (real filesystem) -------------------------------------------

const io = std.testing.io;

fn realRoot(dir: std.Io.Dir, buf: []u8) []const u8 {
    const n = dir.realPath(io, buf) catch @panic("realPath failed in test setup");
    return buf[0..n];
}

/// A workspace dir and a separate "outside" dir holding secret.txt.
const Fixture = struct {
    ws: std.testing.TmpDir,
    outside: std.testing.TmpDir,
    ws_buf: [std.fs.max_path_bytes]u8 = undefined,
    out_buf: [std.fs.max_path_bytes]u8 = undefined,
    ws_root: []const u8 = "",
    out_root: []const u8 = "",

    fn init(self: *Fixture) !void {
        self.ws = std.testing.tmpDir(.{});
        self.outside = std.testing.tmpDir(.{});
        self.ws_root = realRoot(self.ws.dir, &self.ws_buf);
        self.out_root = realRoot(self.outside.dir, &self.out_buf);
        try self.outside.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "secret" });
        try self.ws.dir.writeFile(io, .{ .sub_path = "inside.txt", .data = "ok" });
    }
    fn deinit(self: *Fixture) void {
        self.ws.cleanup();
        self.outside.cleanup();
    }
    fn outsidePath(self: *Fixture, name: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.out_root, name });
    }
    fn policy(self: *Fixture) SecurityPolicy {
        return .{ .workspace_root = self.ws_root };
    }
};

fn expectDenied(p: SecurityPolicy, path: []const u8) !void {
    // Lexically every one of these looks inside the workspace...
    try std.testing.expect(try p.isAllowed(std.testing.allocator, path));
    // ...but the real path escapes.
    try std.testing.expect((try p.resolveReal(std.testing.allocator, io, path)) == null);
}

// Scenario: Given a symlink inside the workspace pointing at a file
// outside it, when resolved for real, then it is denied.
test "symlink to an outside file is denied" {
    var f: Fixture = .{ .ws = undefined, .outside = undefined };
    try f.init();
    defer f.deinit();
    const target = try f.outsidePath("secret.txt");
    defer std.testing.allocator.free(target);
    try f.ws.dir.symLink(io, target, "link.txt", .{});
    try expectDenied(f.policy(), "link.txt");
}

// Scenario: Given a symlinked directory leading outside, when a file below
// it is resolved (existing for a read, or new for a write), then both are
// denied.
test "symlinked directory to outside is denied for reads and new files" {
    var f: Fixture = .{ .ws = undefined, .outside = undefined };
    try f.init();
    defer f.deinit();
    try f.ws.dir.symLink(io, f.out_root, "out", .{ .is_directory = true });
    try expectDenied(f.policy(), "out/secret.txt");
    try expectDenied(f.policy(), "out/new.txt");
    try expectDenied(f.policy(), "out/newdir/new.txt");
}

// Scenario: Given a dangling symlink whose target would be created outside,
// when resolved for a write, then it is denied (writing would follow it).
test "dangling symlink to outside is denied" {
    var f: Fixture = .{ .ws = undefined, .outside = undefined };
    try f.init();
    defer f.deinit();
    const target = try f.outsidePath("created-by-agent.txt");
    defer std.testing.allocator.free(target);
    try f.ws.dir.symLink(io, target, "dangling.txt", .{});
    try expectDenied(f.policy(), "dangling.txt");
}

// Scenario: Given ordinary files, new files, and a symlink that stays inside
// the workspace, when resolved for real, then each is allowed and the real
// path lies under the workspace root.
test "real paths inside the workspace stay allowed" {
    var f: Fixture = .{ .ws = undefined, .outside = undefined };
    try f.init();
    defer f.deinit();
    try f.ws.dir.symLink(io, "inside.txt", "alias.txt", .{});
    const p = f.policy();
    for ([_][]const u8{ "inside.txt", "new.txt", "sub/dir/new.txt", "alias.txt" }) |path| {
        const real = (try p.resolveReal(std.testing.allocator, io, path)) orelse return error.UnexpectedDenial;
        defer std.testing.allocator.free(real);
        try std.testing.expect(std.mem.startsWith(u8, real, f.ws_root));
    }
}

// Scenario: Given an allow-list entry, when a real path lies under it, then
// it is allowed even though it is outside the workspace.
test "real path under an allow-list entry is allowed" {
    var f: Fixture = .{ .ws = undefined, .outside = undefined };
    try f.init();
    defer f.deinit();
    const allow = [_][]const u8{f.out_root};
    const p = SecurityPolicy{ .workspace_root = f.ws_root, .allow = &allow };
    const target = try f.outsidePath("secret.txt");
    defer std.testing.allocator.free(target);
    const real = (try p.resolveReal(std.testing.allocator, io, target)) orelse return error.UnexpectedDenial;
    defer std.testing.allocator.free(real);
    try std.testing.expectEqualStrings(target, real);
}

// Scenario: Given the file_read tool and a symlink to an outside file, when
// the model asks to read the link, then the tool refuses and returns no
// contents.
test "file_read refuses to follow a symlink out of the workspace" {
    var f: Fixture = .{ .ws = undefined, .outside = undefined };
    try f.init();
    defer f.deinit();
    const target = try f.outsidePath("secret.txt");
    defer std.testing.allocator.free(target);
    try f.ws.dir.symLink(io, target, "link.txt", .{});

    const args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"path\":\"link.txt\"}", .{});
    defer args.deinit();
    const p = f.policy();
    const t = opennull.tools.tool.Tool{ .file_read = .{} };
    const result = try t.execute(std.testing.allocator, io, &p, args.value);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("path is outside the allowed workspace", result.err.?);
}
