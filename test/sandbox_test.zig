//! BDD spec for src/security/sandbox.zig — the workspace-scoped allowlist
//! that every filesystem/shell tool must be checked against before touching
//! a path. A bug here is a sandbox escape, so every scenario is written and
//! run red before any implementation exists.
//!
//! Deferred scenario (not covered yet, tracked for a follow-up TDD cycle):
//! a symlink *inside* the workspace that points *outside* it. That requires
//! real filesystem resolution (std.fs.realpath) against on-disk fixtures,
//! not the lexical path-only checks below, and is intentionally out of scope
//! for this first cycle.

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
