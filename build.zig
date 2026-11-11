//! MakePack (Zig port; the C# 1.x original is in git history). docs/ZIG-PORT.md = package table.
//!   zig build                  MakePack.exe + 7z.dll + 7z.sfx + MakePackShell.dll + MakeUpdate.exe in zig-out/bin
//!   zig build test             every unit test (src/test_all.zig)
//!   zig build test-base | test-sevenzip | test-engine | test-platform     one package's tests
//!   zig build test-shell       MakePackShell.dll + shell/test harness (drives the DLL like Explorer)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});
    const kit_dep = b.dependency("makekit", .{ .target = target, .optimize = optimize });
    const kit = kit_dep.module("kit");

    // Absolute paths of the bundled 7-Zip files for tests (the exe finds 7z.dll next to itself).
    // 7z.exe is the test oracle only; it is never installed.
    const paths = b.addOptions();
    paths.addOptionPathUntracked("seven_zip_dll", b.path("third_party/7zip/7z.dll"));
    paths.addOptionPathUntracked("seven_zip_sfx", b.path("third_party/7zip/7z.sfx"));
    paths.addOptionPathUntracked("seven_zip_exe", b.path("third_party/7zip/7z.exe"));
    // The app's version for About and the update check: build.zig.zon's .version, the one place it is kept.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", @import("build.zig.zon").version);
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "kit", .module = kit },
        .{ .name = "paths", .module = paths.createModule() },
        .{ .name = "build_info", .module = build_info.createModule() },
    };

    // ---- MakePack.exe (GUI subsystem; icon 1 + the kit manifest from app.rc)
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = imports });
    exe_mod.addWin32ResourceFile(.{ .file = b.path("app.rc"), .include_paths = &.{kit_dep.namedLazyPath("res")}, .flags = versionDefines(b) });
    const exe = b.addExecutable(.{ .name = "MakePack", .root_module = exe_mod });
    exe.subsystem = .windows;
    b.installArtifact(exe);
    b.installBinFile("third_party/7zip/7z.dll", "7z.dll");
    b.installBinFile("third_party/7zip/7z.sfx", "7z.sfx");
    // MakeUpdate.exe (MakeKit K11): the only networked binary, run by Help > Check for updates and the daily check.
    b.installArtifact(kit_dep.artifact("MakeUpdate"));

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run MakePack").dependOn(&run.step);

    // ---- MakePackShell.dll: the Windows 11 top-level menu (IExplorerCommand), MP-D
    const shell_mod = b.createModule(.{ .root_source_file = b.path("shell/shell.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "kit", .module = kit }} });
    const shell = b.addLibrary(.{ .name = "MakePackShell", .linkage = .dynamic, .root_module = shell_mod });
    b.installArtifact(shell);

    // ---- unit tests: one root per package, test_all = all of them
    const test_all = b.step("test", "Run every unit test");
    test_all.dependOn(addTests(b, "test-all", "src/test_all.zig", target, optimize, imports));
    b.step("test-base", "strings + settings + shared types").dependOn(addTests(b, "test-base", "src/test_base.zig", target, optimize, imports));
    b.step("test-sevenzip", "MP-A: 7z.dll binding").dependOn(addTests(b, "test-sevenzip", "src/test_sevenzip.zig", target, optimize, imports));
    b.step("test-engine", "MP-B: Engine operations").dependOn(addTests(b, "test-engine", "src/test_engine.zig", target, optimize, imports));
    b.step("test-platform", "MP-C: Assoc, single instance, CLI").dependOn(addTests(b, "test-platform", "src/test_platform.zig", target, optimize, imports));

    // ---- test-shell: the C++ harness drives MakePackShell.dll the way Explorer does, against fake_makepack.exe
    const fake = cppExe(b, "fake_makepack", "shell/test/fake_makepack.cpp", target, optimize, &.{});
    const harness = cppExe(b, "harness", "shell/test/harness.cpp", target, optimize, &.{ "ole32", "shell32", "shlwapi", "uuid" });
    const run_harness = b.addRunArtifact(harness);
    run_harness.addArtifactArg(shell);
    run_harness.addArtifactArg(fake);
    // shell.zig's own unit tests (baseName, archiveBase, command-line split, COM lifetime): also part of `test`.
    const shell_tests = &b.addRunArtifact(b.addTest(.{ .name = "shell-test", .root_module = shell_mod })).step;
    test_all.dependOn(shell_tests);
    const test_shell = b.step("test-shell", "MP-D: shell.zig unit tests + build the shell DLL + harness and run the harness");
    test_shell.dependOn(shell_tests);
    test_shell.dependOn(&run_harness.step);
    // The shell DLL alone (tools/build_shell.ps1): no MakePack.exe build needed for packaging the menu.
    b.step("shell", "Build and install MakePackShell.dll only").dependOn(&b.addInstallArtifact(shell, .{}).step);
}

fn addTests(b: *std.Build, name: []const u8, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, imports: []const std.Build.Module.Import) *std.Build.Step {
    const mod = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize, .imports = imports });
    const t = b.addTest(.{ .name = name, .root_module = mod });
    return &b.addRunArtifact(t).step;
}

/// A test-only C++ console exe (static libc++, wmain).
fn cppExe(b: *std.Build, name: []const u8, src: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, libs: []const []const u8) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    mod.addCSourceFile(.{ .file = b.path(src), .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-fms-extensions" } });
    for (libs) |l| mod.linkSystemLibrary(l, .{});
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    exe.mingw_unicode_entry_point = true;
    return exe;
}

/// app.rc's VERSIONINFO numbers and string, from build.zig.zon's .version (the one place it is kept).
fn versionDefines(b: *std.Build) []const []const u8 {
    const ver = @import("build.zig.zon").version;
    const v = std.SemanticVersion.parse(ver) catch @panic("build.zig.zon .version is not semver");
    return b.allocator.dupe([]const u8, &.{
        b.fmt("/DVER_MAJOR={d}", .{v.major}),
        b.fmt("/DVER_MINOR={d}", .{v.minor}),
        b.fmt("/DVER_PATCH={d}", .{v.patch}),
        b.fmt("/DVER_STR=\"{s}\"", .{ver}),
    }) catch @panic("OOM");
}
