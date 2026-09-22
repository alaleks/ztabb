const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_mod = b.createModule(.{
        .root_source_file = b.path("src/sdl.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdl_mod.linkSystemLibrary("SDL3", .{});

    const pty_mod = b.createModule(.{
        .root_source_file = b.path("src/pty.zig"),
        .target = target,
        .optimize = optimize,
    });

    const term_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tabs_mod = b.createModule(.{
        .root_source_file = b.path("src/tabs.zig"),
        .target = target,
        .optimize = optimize,
    });
    tabs_mod.addImport("pty", pty_mod);
    tabs_mod.addImport("term", term_mod);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("sdl", sdl_mod);
    main_mod.addImport("tabs", tabs_mod);
    main_mod.addImport("term", term_mod);

    const exe = b.addExecutable(.{
        .name = "ztabb",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ztabb");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const term_tests = b.addTest(.{ .root_module = term_mod });
    test_step.dependOn(&b.addRunArtifact(term_tests).step);

    const pty_tests = b.addTest(.{ .root_module = pty_mod });
    test_step.dependOn(&b.addRunArtifact(pty_tests).step);

    const tabs_tests = b.addTest(.{ .root_module = tabs_mod });
    test_step.dependOn(&b.addRunArtifact(tabs_tests).step);
}
