const std = @import("std");
const opennull = @import("opennull");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_file_writer.interface;
    try w.print("opennull v{s}\n", .{opennull.version});
    try w.flush();
}

// Scenario: Given the library's exported version string, when read at
// startup, then it follows a semantic "X.Y.Z" shape (two dots).
test "version string matches semantic version format" {
    try std.testing.expect(std.mem.count(u8, opennull.version, ".") == 2);
}
