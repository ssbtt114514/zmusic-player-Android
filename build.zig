//! Zig 构建系统配置文件
//!
//! 定义项目的构建流程，包括：
//! - 共享库（JNI 桥接）：编译为动态链接库供 Java 层通过 JNI 加载

const std = @import("std");

/// 项目构建入口。
///
/// 整体流程：
/// 1. 解析目标平台和优化选项
/// 2. 创建 miniaudio 模块（C 头文件翻译）
/// 3. 构建共享库（JNI 桥接）
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const miniaudio_mod = createMiniaudioModule(b, target, optimize);

    // 平台工具模块（跨平台休眠、时间戳等）
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
    });

    // 歌词类型模块
    const lyrics_types_mod = b.createModule(.{
        .root_source_file = b.path("src/lyrics/types.zig"),
    });

    // 共享库（JNI 桥接）
    // 编译为动态链接库 libzmusic.so，供 Java 层通过 System.loadLibrary 加载
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
    
    // callback 模块作为独立 import，供 bridge.zig 导入事件回调机制
    shared_lib.root_module.addImport("callback", b.createModule(.{
        .root_source_file = b.path("src/jni/callback.zig"),
    }));
    
    // Player 模块（bridge.zig 通过 @import("player") 引入）
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
///
/// 在 Zig 0.16.0 中，Android 使用 .linux 作为操作系统标签，
/// 通过 ABI 为 .android 来区分。
fn isAndroid(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .linux and target.result.abi == .android;
}

/// 创建 miniaudio 绑定模块。
///
/// 通过 Zig 的 @cImport 机制自动翻译 C 头文件，生成可在 Zig 中直接调用的
/// 类型安全绑定，无需手写 FFI 桥接代码。
fn createMiniaudioModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    // 为 Android 平台创建预定义头文件
    const predef_include = if (target.result.os.tag == .linux and target.result.abi == .android) blk: {
        const content =
            \\#define _Nonnull
            \\#define _Nullable
            \\#define _Null_unspecified
        ;
        const file = b.addWriteFile("android_predef.h", content);
        break :blk file.getDirectory();
    } else null;

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/miniaudio/miniaudio.h"),
        .target = target,
        .optimize = optimize,
    });

    // 为 Android 平台特殊处理
    if (target.result.os.tag == .linux and target.result.abi == .android) {
        // 添加预定义头文件目录
        if (predef_include) |dir| {
            translate.addIncludePath(dir);
        }

        // 从 sysroot 添加标准 C 库头文件路径
        if (b.sysroot) |sysroot| {
            translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });

            // 添加架构特定的头文件路径
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

/// 为构建模块应用通用配置。
///
/// 所有需要音频能力的模块都通过此函数统一配置，
/// 确保 miniaudio 导入、C 源文件和平台链接库的一致性。
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
///
/// miniaudio 是纯 C 库，虽然通过 @cImport 翻译了头文件获得了类型定义和函数声明，
/// 但实际的实现代码（miniaudio.c）仍需作为 C 源文件参与编译和链接。
fn addMiniaudioCSources(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    // 为 Android 平台添加宏定义
    const flags = if (isAndroid(target)) &[_][]const u8{
        "-D_Nonnull=",
        "-D_Nullable=",
        "-D_Null_unspecified=",
    } else &.{};

    mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio.c"),
        .flags = flags,
    });
    mod.addIncludePath(b.path("vendor/miniaudio"));
}

/// 链接各平台所需的系统库。
///
/// miniaudio 在不同操作系统上依赖不同的底层音频 API，需要链接对应的系统库：
///
/// - Android：
///   - log：Android 日志库（__android_log_print）
///   - android：Android 原生应用支持库
///   - m：数学库
///   - dl：动态链接库
fn linkPlatformLibs(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    _ = b;
    const os_tag = target.result.os.tag;
    const abi = target.result.abi;

    // Android（在 Zig 中表现为 linux + android ABI）
    if (os_tag == .linux and abi == .android) {
        mod.linkSystemLibrary("log", .{});
        mod.linkSystemLibrary("android", .{});
        mod.linkSystemLibrary("m", .{});
        mod.linkSystemLibrary("dl", .{});
    }
}