const std = @import("std");
const opennull = @import("opennull");
const run = opennull.cli.run;
const chat = opennull.cli.chat;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator: std.mem.Allocator = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_file_writer.interface;

    const argv = try init.minimal.args.toSlice(allocator);
    const args = if (argv.len > 1) argv[1..] else argv[0..0];

    switch (run.parseArgs(args)) {
        .run => |r| try run.execute(allocator, io, init.environ_map, r.prompt, w),
        .chat => try chat.execute(allocator, io, init.environ_map, w),
        .missing_prompt => try w.print("usage: opennull run \"<prompt>\"\n", .{}),
        .unknown => try w.print(
            "opennull v{s}\nusage: opennull\n" ++
                "       opennull run \"<prompt>\"\n" ++
                "       opennull chat\n",
            .{opennull.version},
        ),
    }

    try w.flush();
}

// Scenario: Given the library's exported version string, when read at
// startup, then it follows a semantic "X.Y.Z" shape (two dots).
test "version string matches semantic version format" {
    try std.testing.expect(std.mem.count(u8, opennull.version, ".") == 2);
}
