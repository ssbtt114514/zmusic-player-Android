//! Zig 构建系统配置文件
//!
//! 定义项目的构建流程，包括：
//! - 共享库（JNI 桥接）：编译为动态链接库供 Java 层通过 JNI 加载

const std = @import("std");

/// 项目构建入口。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const miniaudio_mod = createMiniaudioModule(b, target, optimize);

    // 平台工具模块
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
    });

    // 歌词类型模块
    const lyrics_types_mod = b.createModule(.{
        .root_source_file = b.path("src/lyrics/types.zig"),
    });

    // 共享库（JNI 桥接）
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
    shared_lib.root_module.addImport("callback", b.createModule(.{
        .root_source_file = b.path("src/jni/callback.zig"),
    }));

    // Player 模块
    const player_mod_for_lib = b.createModule(.{
        .root_source_file = b.path("src/player.zig"),
    });
    player_mod_for_lib.addImport("miniaudio", miniaudio_mod);
    player_mod_for_lib.addImport("platform", platform_mod);
    player_mod_for_lib.addImport("lyrics_types", lyrics_types_mod);
    shared_lib.root_module.addImport("player", player_mod_for_lib);

    b.installArtifact(shared_lib);

    // Android 构建步骤
    const android_step = b.step(
        "android",
        "Build Android JNI Library",
    );
    android_step.dependOn(&shared_lib.step);
}

/// 判断目标是否为 Android 平台
fn isAndroid(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .linux and target.result.abi == .android;
}

/// 创建 miniaudio 绑定模块。
fn createMiniaudioModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    // Android 平台：使用 wrapper 头文件
    if (isAndroid(target)) {
        const translate = b.addTranslateC(.{
            .root_source_file = b.path("miniaudio_wrapper.h"),
            .target = target,
            .optimize = optimize,
        });

        // 添加必要的 include 路径
        translate.addIncludePath(b.path("vendor/miniaudio"));

        // 添加 NDK sysroot 路径
        if (b.sysroot) |sysroot| {
            translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
            const arch_name = switch (target.result.cpu.arch) {
                .aarch64 => "aarch64-linux-android",
                .arm => "arm-linux-androideabi",
                .x86_64 => "x86_64-linux-android",
                .x86 => "i686-linux-android",
                else => "aarch64-linux-android",
            };
            translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include", arch_name }) });
        }

        return translate.createModule();
    }

    // 非 Android 平台：直接翻译头文件
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/miniaudio/miniaudio.h"),
        .target = target,
        .optimize = optimize,
    });

    return translate.createModule();
}

/// 为构建模块应用通用配置。
fn configureModule(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    miniaudio_mod: *std.Build.Module,
    platform_mod: *std.Build.Module,
) void {
    mod.addImport("miniaudio", miniaudio_mod);
    mod.addImport("platform", platform_mod);
    addMiniaudioCSources(b, mod, target);
    linkPlatformLibs(b, mod, target);
}

/// 添加 miniaudio 的 C 源文件。
fn addMiniaudioCSources(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    _ = target;
    mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio.c"),
        .flags = &.{},
    });
    mod.addIncludePath(b.path("vendor/miniaudio"));
}

/// 链接各平台所需的系统库。
fn linkPlatformLibs(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    _ = b;
    const os_tag = target.result.os.tag;
    const abi = target.result.abi;

    // Android
    if (os_tag == .linux and abi == .android) {
        mod.linkSystemLibrary("log", .{});
        mod.linkSystemLibrary("android", .{});
        mod.linkSystemLibrary("m", .{});
        mod.linkSystemLibrary("dl", .{});
    }
}