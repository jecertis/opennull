//! Literal text search across the sandboxed workspace, so the model can find
//! where things are defined or used. Read-only; never follows symlinks,
//! skips VCS/build/cache directories, binary files and files over 1 MiB.
//! See test/grep_test.zig.
const std = @import("std");
const sandbox = @import("../security/sandbox.zig");
const tool = @import("tool.zig");
const list_dir = @import("list_dir.zig");

const max_matches = 200;
const max_line_bytes = 200;
const max_file_bytes = 1 << 20;

/// Never descended into: VCS metadata, build output, dependencies, and
/// opennull's own local event log.
const skipped_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", ".opennull" };

pub const GrepTool = struct {
    pub fn spec(self: GrepTool, allocator: std.mem.Allocator) !tool.ToolSpec {
        _ = self;
        const schema = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
            \\{"type":"object","properties":{"pattern":{"type":"string","description":"Literal text to search for (not a regex)"},"path":{"type":"string","description":"File or directory to search, relative to the workspace root; defaults to the root"},"ignore_case":{"type":"boolean","description":"Match ASCII letters case-insensitively"}},"required":["pattern"]}
        , .{});
        return .{
            .name = "grep",
            .description = "Search files for literal text; returns 'path:line: text' for each match",
            .parameters_schema = schema,
        };
    }

    pub fn execute(
        self: GrepTool,
        allocator: std.mem.Allocator,
        io: std.Io,
        policy: *const sandbox.SecurityPolicy,
        args: std.json.Value,
    ) !tool.ToolResult {
        _ = self;
        const pattern = switch (list_dir.optionalString(args, "pattern")) {
            .ok => |p| p orelse return .{ .success = false, .output = "", .err = "missing required 'pattern' argument" },
            .bad => |msg| return .{ .success = false, .output = "", .err = msg },
        };
        if (pattern.len == 0) return .{ .success = false, .output = "", .err = "pattern must not be empty" };
        const path = switch (list_dir.optionalString(args, "path")) {
            .ok => |p| p orelse ".",
            .bad => |msg| return .{ .success = false, .output = "", .err = msg },
        };
        const ignore_case = switch (args.object.get("ignore_case") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => return .{ .success = false, .output = "", .err = "'ignore_case' must be a boolean" },
        };

        if (!try policy.isAllowed(allocator, path)) {
            return .{ .success = false, .output = "", .err = "path is outside the allowed workspace" };
        }
        const resolved = (try policy.resolveReal(allocator, io, path)) orelse
            return .{ .success = false, .output = "", .err = "path is outside the allowed workspace" };
        defer allocator.free(resolved);

        var search = Search{ .allocator = allocator, .pattern = pattern, .ignore_case = ignore_case, .out = .init(allocator) };
        errdefer search.out.deinit();

        const stat = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch |err| {
            return .{ .success = false, .output = "", .err = @errorName(err) };
        };
        if (stat.kind == .directory) {
            var dir = std.Io.Dir.cwd().openDir(io, resolved, .{ .iterate = true }) catch |err| {
                return .{ .success = false, .output = "", .err = @errorName(err) };
            };
            defer dir.close(io);
            var walker = try dir.walkSelectively(allocator);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (search.full()) break;
                switch (entry.kind) {
                    .directory => if (!isSkipped(entry.basename)) try walker.enter(io, entry),
                    .file => {
                        const shown = try displayPath(allocator, path, entry.path);
                        defer allocator.free(shown);
                        try search.file(io, entry.dir, entry.basename, shown);
                    },
                    // Symlinks and special files are never read.
                    else => {},
                }
            }
        } else {
            try search.file(io, std.Io.Dir.cwd(), resolved, path);
        }

        if (search.matches == 0) try search.out.writer.writeAll("no matches\n");
        if (search.truncated) try search.out.writer.print("... stopped after {d} matches\n", .{max_matches});
        return .{ .success = true, .output = try search.out.toOwnedSlice() };
    }
};

fn isSkipped(name: []const u8) bool {
    for (skipped_dirs) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// `entry_path` as the model should see it: relative to the workspace when
/// the search started at the root, else prefixed with the requested path.
fn displayPath(allocator: std.mem.Allocator, requested: []const u8, entry_path: []const u8) ![]u8 {
    const base = std.mem.trimEnd(u8, requested, "/");
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return allocator.dupe(u8, entry_path);
    return std.fs.path.join(allocator, &.{ base, entry_path });
}

const Search = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    ignore_case: bool,
    out: std.Io.Writer.Allocating,
    matches: usize = 0,
    truncated: bool = false,

    fn full(self: *const Search) bool {
        return self.truncated;
    }

    fn file(self: *Search, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, shown: []const u8) !void {
        const contents = dir.readFileAlloc(io, sub_path, self.allocator, .limited(max_file_bytes)) catch return;
        defer self.allocator.free(contents);
        // Binary heuristic, as in git and grep: a NUL in the first 8 KiB.
        if (std.mem.indexOfScalar(u8, contents[0..@min(contents.len, 8192)], 0) != null) return;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const hit = if (self.ignore_case)
                std.ascii.indexOfIgnoreCase(line, self.pattern) != null
            else
                std.mem.indexOf(u8, line, self.pattern) != null;
            if (!hit) continue;
            if (self.matches == max_matches) {
                self.truncated = true;
                return;
            }
            self.matches += 1;
            const cut = line[0..@min(line.len, max_line_bytes)];
            try self.out.writer.print("{s}:{d}: {s}{s}\n", .{ shown, line_no, cut, if (cut.len < line.len) " …" else "" });
        }
    }
};
