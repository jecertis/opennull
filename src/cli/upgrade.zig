//! `opennull upgrade` — self-update: query GitHub releases, compare
//! semver, download + replace the running binary. Pure helpers are
//! unit-tested; `execute` is the untestable I/O seam.
const std = @import("std");
const builtin = @import("builtin");
const version = @import("../root.zig").version;

pub const REPO = "jecertis/opennull";

pub const ParsedArgs = union(enum) {
    upgrade: struct { check_only: bool },
    unknown,
};

pub fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len == 0) return .{ .upgrade = .{ .check_only = false } };
    if (std.mem.eql(u8, args[0], "--check") or std.mem.eql(u8, args[0], "-c"))
        return .{ .upgrade = .{ .check_only = true } };
    return .unknown;
}

// ---------------------------------------------------------------------------
// Semver helpers (pure, unit-tested below)
// ---------------------------------------------------------------------------

pub const Semver = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,

    /// Parse "v1.2.3" or "1.2.3". Returns null on malformed input.
    pub fn parse(raw: []const u8) ?Semver {
        var s = raw;
        if (s.len > 0 and s[0] == 'v') s = s[1..];
        var result: Semver = .{};
        result.major = parseUint(&s) orelse return null;
        if (s.len == 0 or s[0] != '.') return null;
        s = s[1..];
        result.minor = parseUint(&s) orelse return null;
        if (s.len == 0 or s[0] != '.') return null;
        s = s[1..];
        result.patch = parseUint(&s) orelse return null;
        if (s.len != 0) return null; // trailing junk
        return result;
    }

    fn parseUint(s: *[]const u8) ?u32 {
        if (s.*.len == 0 or s.*[0] < '0' or s.*[0] > '9') return null;
        var val: u32 = 0;
        while (s.*.len > 0 and s.*[0] >= '0' and s.*[0] <= '9') {
            val = val * 10 + (s.*[0] - '0');
            s.* = s.*[1..];
        }
        return val;
    }

    pub fn order(a: Semver, b: Semver) std.math.Order {
        const major_ord = std.math.order(a.major, b.major);
        if (major_ord != .eq) return major_ord;
        const minor_ord = std.math.order(a.minor, b.minor);
        if (minor_ord != .eq) return minor_ord;
        return std.math.order(a.patch, b.patch);
    }

    pub fn format(self: Semver, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

// ---------------------------------------------------------------------------
// Platform detection (pure)
// ---------------------------------------------------------------------------

pub const Platform = struct {
    target: []const u8,

    pub fn detect() Platform {
        return .{ .target = comptime blk: {
            const arch: []const u8 = switch (builtin.cpu.arch) {
                .x86_64 => "x86_64",
                .aarch64 => "aarch64",
                else => "unknown",
            };
            const os: []const u8 = if (builtin.os.tag == .macos) "macos" else "linux";
            const result = arch ++ "-" ++ os;
            break :blk result;
        } };
    }
};

// ---------------------------------------------------------------------------
// GitHub releases API (pure parser)
// ---------------------------------------------------------------------------

/// Extract "tag_name" from the raw GitHub releases/latest JSON response.
pub fn extractLatestTag(json: []const u8) ?[]const u8 {
    const needle = "\"tag_name\"";
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const after_key = json[start + needle.len ..];
    const q1 = std.mem.indexOfScalar(u8, after_key, '"') orelse return null;
    const value_start = q1 + 1;
    const q2 = std.mem.indexOfScalar(u8, after_key[value_start..], '"') orelse return null;
    return after_key[value_start .. value_start + q2];
}

/// Extract "browser_download_url" for the asset matching `target` from the
/// GitHub releases/latest JSON.
pub fn extractAssetUrl(json: []const u8, target: []const u8) ?[]const u8 {
    var remaining = json;
    while (std.mem.indexOf(u8, remaining, "browser_download_url")) |pos| {
        const after = remaining[pos..];
        const q1 = std.mem.indexOfScalar(u8, after, '"') orelse return null;
        const val_start = q1 + 1;
        const q2 = std.mem.indexOfScalar(u8, after[val_start..], '"') orelse return null;
        const url = after[val_start .. val_start + q2];
        if (std.mem.indexOf(u8, url, target) != null) return url;
        remaining = after[val_start + q2 ..];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Version comparison helpers
// ---------------------------------------------------------------------------

pub fn isNewer(a: Semver, b: Semver) bool {
    return a.order(b) == .gt;
}

// ---------------------------------------------------------------------------
// Execute (untestable I/O seam)
// ---------------------------------------------------------------------------

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    self_path: []const u8,
    stdout: *std.Io.Writer,
) !void {
    const parsed = parseArgs(args);
    switch (parsed) {
        .unknown => {
            try stdout.print("usage: opennull upgrade [--check]\n", .{});
            return;
        },
        .upgrade => |u| return runUpgrade(allocator, io, u.check_only, self_path, stdout),
    }
}

fn runUpgrade(
    allocator: std.mem.Allocator,
    io: std.Io,
    check_only: bool,
    self_path: []const u8,
    stdout: *std.Io.Writer,
) !void {
    const current = Semver.parse(version) orelse {
        try stdout.print("error: cannot parse built-in version {s}\n", .{version});
        return;
    };

    const platform = Platform.detect();

    try stdout.print("==> checking for updates (current: v{s}, {s})\n", .{ version, platform.target });

    // 1. Fetch latest release JSON from GitHub
    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{REPO});
    defer allocator.free(api_url);

    const json_body = curlFetch(allocator, io, api_url) catch |err| {
        try stdout.print("error: failed to check GitHub ({t})\n", .{err});
        return;
    };
    defer allocator.free(json_body);

    // 2. Parse latest tag
    const latest_tag = extractLatestTag(json_body) orelse {
        try stdout.print("error: could not parse GitHub response\n", .{});
        return;
    };
    const latest = Semver.parse(latest_tag) orelse {
        try stdout.print("error: could not parse version tag {s}\n", .{latest_tag});
        return;
    };

    if (!isNewer(latest, current)) {
        try stdout.print("==> already up to date (v{s})\n", .{version});
        return;
    }

    if (check_only) {
        try stdout.print("==> update available: v{s} -> v{s}\n", .{ version, latest_tag });
        return;
    }

    try stdout.print("==> downloading v{s}...\n", .{latest_tag});

    // 3. Download the tarball for this platform
    const asset_url = extractAssetUrl(json_body, platform.target) orelse {
        try stdout.print("error: no binary found for {s} in release {s}\n", .{ platform.target, latest_tag });
        return;
    };

    // Download tarball to a temp file
    var tmp_buf: [64]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "/tmp/opennull-update-{d}", .{std.c.getpid()}) catch return;
    const tarball_path = try allocator.dupe(u8, tmp_path);
    defer allocator.free(tarball_path);

    curlToFile(allocator, io, asset_url, tarball_path) catch |err| {
        try stdout.print("error: download failed ({t})\n", .{err});
        return;
    };
    defer std.Io.Dir.cwd().deleteFile(io, tarball_path) catch {};

    // 4. Extract tarball to a temp directory
    var tmp_dir_buf: [80]u8 = undefined;
    const tmp_dir_path = std.fmt.bufPrint(&tmp_dir_buf, "/tmp/opennull-extract-{d}", .{std.c.getpid()}) catch return;
    const tmp_dir = try allocator.dupe(u8, tmp_dir_path);
    defer allocator.free(tmp_dir);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    std.Io.Dir.cwd().createDir(io, tmp_dir, .default_dir) catch {};
    _ = runCommand(allocator, io, &.{ "tar", "-xzf", tarball_path, "-C", tmp_dir }) catch |err| {
        try stdout.print("error: tar extraction failed ({t})\n", .{err});
        return;
    };

    // 5. Find the extracted binary (name varies: opennull-vX.Y.Z-arch-os/opennull)
    var extracted_bin: ?[]const u8 = null;
    var dir = std.Io.Dir.cwd().openDir(io, tmp_dir, .{}) catch |err| {
        try stdout.print("error: could not open temp dir ({t})\n", .{err});
        return;
    };
    defer dir.close(io);

    var walker = dir.walk(allocator) catch |err| {
        try stdout.print("error: could not walk temp dir ({t})\n", .{err});
        return;
    };
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (std.mem.eql(u8, entry.basename, "opennull")) {
            // Build the full path relative to cwd
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, entry.path });
            extracted_bin = full;
            break;
        }
    }

    const bin_path = extracted_bin orelse {
        try stdout.print("error: could not find opennull binary in downloaded archive\n", .{});
        return;
    };
    defer allocator.free(bin_path);

    // 6. Replace self: write new binary, make executable
    const new_content = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(new_content);

    // Remove old, write new
    std.Io.Dir.cwd().deleteFile(io, self_path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self_path, .data = new_content });
    try std.Io.Dir.cwd().setFilePermissions(io, self_path, .executable_file, .{});

    try stdout.print("==> upgraded v{s} -> v{s}\n", .{ version, latest_tag });
}

// ---------------------------------------------------------------------------
// Subprocess helpers (uses std.process.run)
// ---------------------------------------------------------------------------

/// Fetch URL via curl, return body as owned slice. Caller frees.
fn curlFetch(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-fsSL", url },
        .stdout_limit = .unlimited,
    }) catch return error.FetchFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.FetchFailed,
        else => return error.FetchFailed,
    }
    return try allocator.dupe(u8, result.stdout);
}

/// Fetch URL via curl, write to file.
fn curlToFile(allocator: std.mem.Allocator, io: std.Io, url: []const u8, path: []const u8) !void {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-fsSL", "-o", path, url },
    }) catch return error.FetchFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.FetchFailed,
        else => return error.FetchFailed,
    }
}

/// Run a command, return exit code.
fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch return error.CommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code,
        else => error.CommandFailed,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseArgs no args" {
    const r = parseArgs(&.{});
    try std.testing.expect(r.upgrade.check_only == false);
}

test "parseArgs --check" {
    const r = parseArgs(&.{ "--check" });
    try std.testing.expect(r.upgrade.check_only);
}

test "parseArgs unknown" {
    const r = parseArgs(&.{ "foo" });
    try std.testing.expectEqual(ParsedArgs.unknown, r);
}

test "semver parse valid" {
    const v = Semver.parse("v1.2.3") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 2), v.minor);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
}

test "semver parse without v prefix" {
    const v = Semver.parse("0.1.2") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u32, 0), v.major);
    try std.testing.expectEqual(@as(u32, 1), v.minor);
    try std.testing.expectEqual(@as(u32, 2), v.patch);
}

test "semver parse invalid" {
    try std.testing.expectEqual(@as(?Semver, null), Semver.parse("not-a-version"));
    try std.testing.expectEqual(@as(?Semver, null), Semver.parse("1.2"));
    try std.testing.expectEqual(@as(?Semver, null), Semver.parse("1.2.3.4"));
}

test "semver order" {
    const a = Semver{ .major = 0, .minor = 2, .patch = 0 };
    const b = Semver{ .major = 0, .minor = 1, .patch = 9 };
    try std.testing.expectEqual(std.math.Order.gt, a.order(b));
}

test "isNewer" {
    const newer = Semver{ .major = 1, .minor = 0, .patch = 0 };
    const older = Semver{ .major = 0, .minor = 9, .patch = 9 };
    try std.testing.expect(isNewer(newer, older));
    try std.testing.expect(!isNewer(older, newer));
    try std.testing.expect(!isNewer(newer, newer));
}

test "extractLatestTag" {
    const json =
        \\{"tag_name":"v0.2.0","name":"Release 0.2.0"}
    ;
    const tag = extractLatestTag(json) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("v0.2.0", tag);
}

test "extractAssetUrl" {
    const json =
        \\{"assets":[{"browser_download_url":"https://example.com/opennull-v0.2.0-x86_64-macos.tar.gz","name":"opennull-v0.2.0-x86_64-macos.tar.gz"}]}
    ;
    const url = extractAssetUrl(json, "x86_64-macos") orelse return error.TestUnexpectedNull;
    try std.testing.expect(std.mem.indexOf(u8, url, "x86_64-macos") != null);
}
