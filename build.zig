const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const miniaudio_mod = createMiniaudioModule(b, target, optimize);
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
    });
    const lyrics_types_mod = b.createModule(.{
        .root_source_file = b.path("src/lyrics/types.zig"),
    });

    // 共享库
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zmusic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/jni/bridge.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureModule(b, shared_lib.root_module, target, miniaudio_mod, platform_mod);
    
    // callback 模块
    const callback_mod = b.createModule(.{
        .root_source_file = b.path("src/jni/callback.zig"),
    });
    shared_lib.root_module.addImport("callback", callback_mod);

    // player 模块
    const player_mod = b.createModule(.{
        .root_source_file = b.path("src/player.zig"),
    });
    player_mod.addImport("miniaudio", miniaudio_mod);
    player_mod.addImport("platform", platform_mod);
    player_mod.addImport("lyrics_types", lyrics_types_mod);
    shared_lib.root_module.addImport("player", player_mod);

    // Android 库路径
    if (target.result.os.tag == .linux and target.result.abi == .android) {
        if (b.graph.env_map.get("ANDROID_LIB_DIR")) |lib_dir| {
            // 0.16.0+ 使用 addSystemLibraryPath
            shared_lib.root_module.addSystemLibraryPath(.{ .cwd_relative = lib_dir });
        }
    }

    b.installArtifact(shared_lib);

    // 可执行文件
    const exe = b.addExecutable(.{
        .name = "zmusic-player",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureModule(b, exe.root_module, target, miniaudio_mod, platform_mod);
    exe.root_module.addImport("lyrics_types", lyrics_types_mod);
    b.installArtifact(exe);

    // 运行
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "运行应用");
    run_step.dependOn(&run_cmd.step);

    // 测试
    const test_step = b.step("test", "运行单元测试");

    // main 测试
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureModule(b, main_tests.root_module, target, miniaudio_mod, platform_mod);
    main_tests.root_module.addImport("lyrics_types", lyrics_types_mod);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);

    // 歌词解析测试
    const lyrics_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/lyrics/parser.zig"),
    });
    lyrics_parser_mod.addImport("lyrics_types", lyrics_types_mod);
    addModuleTest(b, test_step, target, optimize, miniaudio_mod, platform_mod, "tests/test_lyrics.zig", &.{
        .{ "lyrics_parser", lyrics_parser_mod },
        .{ "lyrics", lyrics_types_mod },
    });

    // 队列测试
    const queue_mod = b.createModule(.{
        .root_source_file = b.path("src/queue/playlist.zig"),
    });
    queue_mod.addImport("platform", platform_mod);
    addModuleTest(b, test_step, target, optimize, miniaudio_mod, platform_mod, "tests/test_queue.zig", &.{
        .{ "queue", queue_mod },
    });

    // Player 测试（复用 player_mod）
    const player_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_player.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    player_test.root_module.addImport("miniaudio", miniaudio_mod);
    player_test.root_module.addImport("platform", platform_mod);
    player_test.root_module.addImport("player", player_mod);
    addMiniaudioCSources(b, player_test.root_module);
    linkPlatformLibs(b, player_test.root_module, target);
    test_step.dependOn(&b.addRunArtifact(player_test).step);
}

fn createMiniaudioModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/wrapper.h"),
        .target = target,
        .optimize = optimize,
    });

    if (target.result.os.tag == .linux and target.result.abi == .android) {
        if (b.sysroot) |sysroot| {
            const arch_include = switch (target.result.cpu.arch) {
                .aarch64 => "aarch64-linux-android",
                .x86_64 => "x86_64-linux-android",
                else => null,
            };
            // 0.16.0+ 使用 addIncludePath
            translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
            if (arch_include) |arch| {
                translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include", arch }) });
            }
        }
    }

    return translate.createModule();
}

fn configureModule(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    miniaudio_mod: *std.Build.Module,
    platform_mod: *std.Build.Module,
) void {
    mod.addImport("miniaudio", miniaudio_mod);
    mod.addImport("platform", platform_mod);
    addMiniaudioCSources(b, mod);
    linkPlatformLibs(b, mod, target);
}

fn addModuleTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    miniaudio_mod: *std.Build.Module,
    platform_mod: *std.Build.Module,
    test_path: []const u8,
    imports: []const struct { []const u8, *std.Build.Module },
) void {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(test_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    t.root_module.addImport("miniaudio", miniaudio_mod);
    t.root_module.addImport("platform", platform_mod);
    for (imports) |imp| {
        t.root_module.addImport(imp[0], imp[1]);
    }
    linkPlatformLibs(b, t.root_module, target);
    test_step.dependOn(&b.addRunArtifact(t).step);
}

fn addMiniaudioCSources(b: *std.Build, mod: *std.Build.Module) void {
    mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio.c"),
        .flags = &.{},
    });
    mod.addIncludePath(b.path("vendor/miniaudio"));
}

fn linkPlatformLibs(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .linux => {
            if (target.result.abi == .android) {
                mod.linkSystemLibrary("OpenSLES", .{});
                mod.linkSystemLibrary("log", .{});
            } else {
                mod.linkSystemLibrary("pthread", .{});
                mod.linkSystemLibrary("m", .{});
                mod.linkSystemLibrary("dl", .{});
            }
        },
        .windows => {
            mod.linkSystemLibrary("winmm", .{});
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("uuid", .{});
        },
        .macos => {
            // 0.16.0+ 的 SDK 获取方式
            const sdk = blk: {
                if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, target.result)) |sdk_path| {
                    break :blk sdk_path;
                } else |_| {
                    break :blk b.graph.env_map.get("SDKROOT") orelse b.sysroot;
                }
            };

            if (sdk) |path| {
                // 0.16.0+ 使用 addFrameworkPath 和 addSystemLibraryPath
                mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ path, "System/Library/Frameworks" }) });
                mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ path, "usr/include" }) });
                mod.addSystemLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ path, "usr/lib" }) });
                mod.linkSystemLibrary("iconv", .{});
                mod.linkFramework("CoreAudio", .{});
                mod.linkFramework("AudioToolbox", .{});
                mod.linkFramework("CoreFoundation", .{});
            }
        },
        else => {},
    }
}