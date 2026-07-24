//! Zig 构建系统配置文件
//!
//! 定义项目的构建流程，包括：
//! - 共享库（JNI 桥接）：编译为动态链接库供 Java 层通过 JNI 加载

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

    shared_lib.root_module.addImport("miniaudio", miniaudio_mod);
    shared_lib.root_module.addImport("platform", platform_mod);
    
    shared_lib.root_module.addImport("callback", b.createModule(.{
        .root_source_file = b.path("src/jni/callback.zig"),
    }));

    const player_mod_for_lib = b.createModule(.{
        .root_source_file = b.path("src/player.zig"),
    });
    player_mod_for_lib.addImport("miniaudio", miniaudio_mod);
    player_mod_for_lib.addImport("platform", platform_mod);
    player_mod_for_lib.addImport("lyrics_types", lyrics_types_mod);
    shared_lib.root_module.addImport("player", player_mod_for_lib);

    // 添加 C 源文件
    shared_lib.root_module.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio.c"),
        .flags = &.{},
    });
    shared_lib.root_module.addIncludePath(b.path("vendor/miniaudio"));

    // 链接 Android 库
    if (target.result.os.tag == .linux and target.result.abi == .android) {
        shared_lib.root_module.linkSystemLibrary("log", .{});
        shared_lib.root_module.linkSystemLibrary("android", .{});
        shared_lib.root_module.linkSystemLibrary("m", .{});
        shared_lib.root_module.linkSystemLibrary("dl", .{});
    }

    b.installArtifact(shared_lib);

    const android_step = b.step("android", "Build Android JNI Library");
    android_step.dependOn(&shared_lib.step);
}

fn createMiniaudioModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const is_android = target.result.os.tag == .linux and target.result.abi == .android;
    
    // Android 使用 wrapper，其他平台直接使用 miniaudio.h
    const header_file = if (is_android) 
        b.path("miniaudio_wrapper.h") 
    else 
        b.path("vendor/miniaudio/miniaudio.h");

    const translate = b.addTranslateC(.{
        .root_source_file = header_file,
        .target = target,
        .optimize = optimize,
    });

    if (is_android) {
        translate.addIncludePath(b.path("vendor/miniaudio"));
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
    }

    return translate.createModule();
}