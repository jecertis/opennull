const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tui_enabled = b.option(bool, "tui", "Enable the optional terminal UI") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "tui_enabled", tui_enabled);

    // Library module re-exporting all internal submodules (security, tools,
    // router, provider, agent, ...) so both the exe and every test file can
    // `@import("opennull")` a single stable entry point.
    const opennull_mod = b.addModule("opennull", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    opennull_mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "opennull",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "opennull", .module = opennull_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run opennull");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Unit tests for the library module itself (co-located `test` blocks
    // reachable from src/root.zig).
    const mod_tests = b.addTest(.{ .root_module = opennull_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Unit tests for the executable's own root module (main.zig).
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // BDD-scenario test files under test/, each imports the "opennull"
    // module and is wired as its own test binary here as they're added.
    const test_files = [_][]const u8{
        "test/sandbox_test.zig",
        "test/dotenv_test.zig",
        "test/toml_test.zig",
        "test/config_test.zig",
        "test/anthropic_test.zig",
        "test/http_test.zig",
        "test/run_test.zig",
        "test/file_read_test.zig",
        "test/file_write_test.zig",
        "test/file_edit_test.zig",
        "test/registry_test.zig",
        "test/openai_compat_test.zig",
    };
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    for (test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "opennull", .module = opennull_mod },
                },
            }),
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
