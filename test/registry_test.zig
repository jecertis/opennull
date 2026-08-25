//! BDD spec for src/tools/registry.zig — the compile-time enabled-tool list
//! and the specs/dispatch built from it.
const std = @import("std");
const opennull = @import("opennull");
const registry = opennull.tools.registry;
const tool = opennull.tools.tool;

// Scenario: Given the enabled tools, when their specs are built, then there
// is exactly one spec per enabled tool.
test "buildSpecs returns one spec per enabled tool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const specs = try registry.buildSpecs(arena.allocator());
    try std.testing.expectEqual(registry.enabled_tools.len, specs.len);
}

// Scenario: Given the built specs, when their names are compared, then no
// two tools declare the same name (the provider's function-calling schema
// would be ambiguous otherwise).
test "spec names are unique" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const specs = try registry.buildSpecs(arena.allocator());
    for (specs, 0..) |a, i| {
        for (specs[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

// Scenario: Given a known tool name, when looked up, then the matching
// enabled Tool is returned with the same tag.
test "find locates a tool by name" {
    const found = registry.find("file_edit");
    try std.testing.expect(found != null);
    try std.testing.expectEqual(tool.ToolTag.file_edit, std.meta.activeTag(found.?));
}

// Scenario: Given an unknown tool name, when looked up, then find returns
// null rather than panicking or matching the wrong tool.
test "find returns null for an unknown tool name" {
    const found = registry.find("does_not_exist");
    try std.testing.expect(found == null);
}

// Scenario: Given a tool's active tag, when its name is read, then it
// matches exactly the name declared in its own spec (no drift between the
// dispatch key and the LLM-facing tool name).
test "tool name matches its own spec name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const t = tool.Tool{ .file_read = .{} };
    const spec = try t.spec(arena.allocator());
    try std.testing.expectEqualStrings(spec.name, t.name());
}
