const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = struct {
        fn make(bb: *std.Build, path: []const u8, t: anytype, o: anytype) *std.Build.Module {
            return bb.createModule(.{
                .root_source_file = bb.path(path),
                .target = t,
                .optimize = o,
                .link_libc = true,
            });
        }
    }.make;

    const theme_mod = mod(b, "src/theme.zig", target, optimize);
    const font_mod = mod(b, "src/font.zig", target, optimize);
    const icons_mod = mod(b, "src/icons.zig", target, optimize);
    const appicon_mod = mod(b, "src/appicon.zig", target, optimize);
    const png_mod = mod(b, "src/png.zig", target, optimize);
    const panes_mod = mod(b, "src/panes.zig", target, optimize);
    const macos_mod = mod(b, "src/macos.zig", target, optimize);
    // The Objective-C runtime, for the handful of window calls SDL does not
    // wrap. Nothing else in the project touches it.
    if (target.result.os.tag.isDarwin()) macos_mod.linkSystemLibrary("objc", .{});
    const pty_mod = mod(b, "src/pty.zig", target, optimize);
    // openpty and login_tty live in libutil on Linux and the BSDs; on macOS
    // they are part of libc, which is already linked.
    if (target.result.os.tag == .linux) pty_mod.linkSystemLibrary("util", .{});
    const ssh_mod = mod(b, "src/ssh.zig", target, optimize);

    const sdl_mod = mod(b, "src/sdl.zig", target, optimize);
    // Windows has no standard place for libraries, so point the search at
    // whatever installed SDL3 -- vcpkg by default.
    if (target.result.os.tag == .windows) {
        const sdl_root = b.option([]const u8, "sdl3", "Path to an SDL3 install (Windows)") orelse
            b.graph.environ_map.get("SDL3_ROOT");
        if (sdl_root) |root| {
            sdl_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "include" }) });
            sdl_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "lib" }) });
        }
    }
    sdl_mod.linkSystemLibrary("SDL3", .{});

    const term_mod = mod(b, "src/terminal.zig", target, optimize);
    term_mod.addImport("theme", theme_mod);

    const highlight_mod = mod(b, "src/highlight.zig", target, optimize);
    highlight_mod.addImport("theme", theme_mod);

    const tabs_mod = mod(b, "src/tabs.zig", target, optimize);
    tabs_mod.addImport("pty", pty_mod);
    tabs_mod.addImport("term", term_mod);
    tabs_mod.addImport("ssh", ssh_mod);
    tabs_mod.addImport("panes", panes_mod);

    const render_mod = mod(b, "src/render.zig", target, optimize);
    render_mod.addImport("sdl", sdl_mod);
    render_mod.addImport("font", font_mod);
    render_mod.addImport("icons", icons_mod);
    render_mod.addImport("term", term_mod);
    render_mod.addImport("theme", theme_mod);
    render_mod.addImport("highlight", highlight_mod);
    render_mod.addImport("tabs", tabs_mod);
    render_mod.addImport("panes", panes_mod);

    const app_mod = mod(b, "src/app.zig", target, optimize);
    app_mod.addImport("sdl", sdl_mod);
    app_mod.addImport("tabs", tabs_mod);
    app_mod.addImport("term", term_mod);
    app_mod.addImport("theme", theme_mod);
    app_mod.addImport("ssh", ssh_mod);
    app_mod.addImport("render", render_mod);
    app_mod.addImport("panes", panes_mod);
    app_mod.addImport("appicon", appicon_mod);
    app_mod.addImport("macos", macos_mod);
    app_mod.addImport("font", font_mod);

    const main_mod = mod(b, "src/main.zig", target, optimize);
    main_mod.addImport("app", app_mod);

    const exe = b.addExecutable(.{ .name = "ztabb", .root_module = main_mod });
    // `tools/bundle.sh` rewrites the SDL3 load path to one inside the bundle,
    // and a Mach-O header has only the padding the linker left it. On arm64 the
    // Homebrew path it replaces happens to be about as long, so it fits; on
    // x86_64 Homebrew lives under /usr/local, the replacement is longer, and
    // install_name_tool refuses -- "larger updated load commands do not fit".
    // Reserving the room up front is the fix it asks for.
    if (target.result.os.tag.isDarwin()) exe.headerpad_max_install_names = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ztabb").dependOn(&run_cmd.step);

    // `zig build icon` renders the icon at every size an .icns carries and
    // hands the directory to iconutil; `zig build bundle` wraps the binary and
    // that icon into ztabb.app, which is what macOS needs to show the icon in
    // the Dock and Finder rather than only while the program runs.
    const mkiconset_mod = mod(b, "tools/mkiconset.zig", b.graph.host, .Debug);
    mkiconset_mod.addImport("appicon", appicon_mod);
    mkiconset_mod.addImport("png", png_mod);
    const mkiconset = b.addExecutable(.{ .name = "mkiconset", .root_module = mkiconset_mod });

    const iconset_dir = "zig-out/ztabb.iconset";
    const run_mkiconset = b.addRunArtifact(mkiconset);
    run_mkiconset.addArg(iconset_dir);

    const iconutil = b.addSystemCommand(&.{ "iconutil", "-c", "icns", "-o", "zig-out/ztabb.icns", iconset_dir });
    iconutil.step.dependOn(&run_mkiconset.step);
    const icon_step = b.step("icon", "Render zig-out/ztabb.icns");
    icon_step.dependOn(&iconutil.step);

    const mklogo_mod = mod(b, "tools/mklogo.zig", b.graph.host, .Debug);
    mklogo_mod.addImport("appicon", appicon_mod);
    mklogo_mod.addImport("png", png_mod);
    const mklogo = b.addExecutable(.{ .name = "mklogo", .root_module = mklogo_mod });
    const run_mklogo = b.addRunArtifact(mklogo);
    run_mklogo.addArg("zig-out/logo");
    // ffmpeg turns the two frames into the blinking mark the README shows.
    const logo_gif = b.addSystemCommand(&.{
        "ffmpeg",           "-y",                                                                        "-loglevel", "error",
        "-framerate",       "1.6",                                                                       "-i",        "zig-out/logo/logo-%d.png",
        "-vf",              "scale=256:256:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop",     "0",
        ".github/logo.gif",
    });
    logo_gif.step.dependOn(&run_mklogo.step);
    b.step("logo", "Render .github/logo.gif").dependOn(&logo_gif.step);

    const bundle = b.addSystemCommand(&.{ "sh", "tools/bundle.sh" });
    bundle.step.dependOn(&iconutil.step);
    bundle.step.dependOn(b.getInstallStep());
    const bundle_step = b.step("bundle", "Build zig-out/ztabb.app");
    bundle_step.dependOn(&bundle.step);

    // Narrows every suite to the tests whose name contains this, which is how
    // a suite that hangs somewhere in the middle gets bisected down to the test
    // that does it -- a test binary killed for not responding says nothing
    // about where it was.
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this");

    const test_step = b.step("test", "Run unit tests");
    // Builds the suites and puts them somewhere nameable, without running any.
    //
    // A test binary run through `zig build` talks to the build runner over a
    // pipe, so its per-test progress is protocol and never reaches a log: a
    // suite that stops answering is killed having said nothing about where it
    // was. Run directly, the same binary prints each test's name before it runs
    // it, which is the only way to find out. This step is how CI gets hold of
    // one -- digging through .zig-cache for it works until the build was cut
    // short and the binary is not there.
    const test_bin_step = b.step("test-bin", "Build the test binaries without running them");
    // Everything but the SDL-facing modules, so a machine without SDL3 can
    // still check the terminal, the pty, the typeface and the parsers.
    const core_step = b.step("test-core", "Run unit tests that do not need SDL3");

    const core_suites = [_][]const u8{
        "theme",    "font",      "icons",     "appicon", "png",
        "terminal", "highlight", "ssh",       "pty",     "tabs",
        "macos",    "panes",     "pty-posix",
    };

    // `src/pty_posix.zig` cannot be built on Windows: it reaches for `environ`
    // and `openpty`. The Windows implementation needs no suite of its own --
    // it holds no tests, and `pty.zig` imports it there, so the `pty` suite
    // compiles it already.
    const pty_posix_mod = mod(b, "src/pty_posix.zig", target, optimize);
    // As for `pty_mod`: openpty and login_tty live in libutil on Linux.
    if (target.result.os.tag == .linux) pty_posix_mod.linkSystemLibrary("util", .{});

    const suites = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "font", .module = font_mod },
        .{ .name = "icons", .module = icons_mod },
        .{ .name = "appicon", .module = appicon_mod },
        .{ .name = "png", .module = png_mod },
        .{ .name = "panes", .module = panes_mod },
        .{ .name = "macos", .module = macos_mod },
        .{ .name = "terminal", .module = term_mod },
        .{ .name = "highlight", .module = highlight_mod },
        .{ .name = "ssh", .module = ssh_mod },
        .{ .name = "pty", .module = pty_mod },
        .{ .name = "pty-posix", .module = pty_posix_mod },
        .{ .name = "tabs", .module = tabs_mod },
        .{ .name = "sdl", .module = sdl_mod },
        .{ .name = "render", .module = render_mod },
        .{ .name = "app", .module = app_mod },
    };
    for (suites) |s| {
        if (std.mem.eql(u8, s.name, "pty-posix") and target.result.os.tag == .windows) continue;
        const t = b.addTest(.{
            .name = s.name,
            .root_module = s.module,
            .filters = if (test_filter) |f| &.{f} else &.{},
        });
        const run = &b.addRunArtifact(t).step;
        test_step.dependOn(run);
        for (core_suites) |core| {
            if (std.mem.eql(u8, core, s.name)) core_step.dependOn(run);
        }

        const installed = b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "test" } },
        });
        test_bin_step.dependOn(&installed.step);
    }
}
