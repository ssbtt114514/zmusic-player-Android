//! Zig 构建系统配置文件

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 解析 Android NDK sysroot 路径。
    // 优先级：--sysroot > ANDROID_NDK_HOME > ANDROID_NDK_ROOT
    // 在 Windows 上推荐使用 ANDROID_NDK_HOME 而非 --sysroot，
    // 因为 --sysroot 会导致链接器把 sysroot 前缀错误地拼到绝对 -L 路径前。
    const android_sysroot: ?[]const u8 = blk: {
        if (b.sysroot) |s| break :blk s;
        const env_map = &b.graph.environ_map;
        if (env_map.get("ANDROID_NDK_HOME")) |ndk_home| {
            if (ndk_home.len > 0) {
                const host_tag = if (builtin.os.tag == .windows)
                    "windows-x86_64"
                else if (builtin.os.tag == .macos)
                    "darwin-x86_64"
                else
                    "linux-x86_64";
                break :blk b.pathJoin(&.{
                    ndk_home,
                    "toolchains/llvm/prebuilt",
                    host_tag,
                    "sysroot",
                });
            }
        }
        if (env_map.get("ANDROID_NDK_ROOT")) |ndk_root| {
            if (ndk_root.len > 0) {
                const host_tag = if (builtin.os.tag == .windows)
                    "windows-x86_64"
                else if (builtin.os.tag == .macos)
                    "darwin-x86_64"
                else
                    "linux-x86_64";
                break :blk b.pathJoin(&.{
                    ndk_root,
                    "toolchains/llvm/prebuilt",
                    host_tag,
                    "sysroot",
                });
            }
        }
        break :blk null;
    };

    const miniaudio_mod = createMiniaudioModule(b, target, optimize, android_sysroot);

    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
    });

    const lyrics_types_mod = b.createModule(.{
        .root_source_file = b.path("src/lyrics/types.zig"),
    });

    const android_log_mod = b.createModule(.{
        .root_source_file = b.path("src/android_log.zig"),
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
    shared_lib.root_module.addImport("android_log", android_log_mod);

    const player_mod_for_lib = b.createModule(.{
        .root_source_file = b.path("src/player.zig"),
    });
    player_mod_for_lib.addImport("miniaudio", miniaudio_mod);
    player_mod_for_lib.addImport("platform", platform_mod);
    player_mod_for_lib.addImport("lyrics_types", lyrics_types_mod);
    player_mod_for_lib.addImport("android_log", android_log_mod);
    shared_lib.root_module.addImport("player", player_mod_for_lib);

    // 添加 C 源文件
    shared_lib.root_module.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio.c"),
        .flags = &.{},
    });
    shared_lib.root_module.addIncludePath(b.path("vendor/miniaudio"));

    // Android 特定配置
    if (target.result.os.tag == .linux and target.result.abi == .android) {
        const arch_name = switch (target.result.cpu.arch) {
            .aarch64 => "aarch64-linux-android",
            .arm => "arm-linux-androideabi",
            .x86_64 => "x86_64-linux-android",
            .x86 => "i686-linux-android",
            else => "aarch64-linux-android",
        };
        const api_level = "21";

        // 添加 NDK include 路径（用于编译 miniaudio.c 等 C 源文件）
        if (android_sysroot) |sysroot| {
            shared_lib.root_module.addIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }),
            });
            shared_lib.root_module.addIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include", arch_name }),
            });
        }

        // 添加 NDK 库搜索路径
        // 优先级：ANDROID_LIB_DIR > android_sysroot 推导
        // 注意：当 --sysroot 传入时，链接器会把 sysroot 前缀拼到 -L 路径前。
        // 在 Windows 上这会导致路径重复（sysroot + 绝对路径），
        // 因此当使用 --sysroot 时，库路径使用相对形式（usr/lib/...）；
        // 否则使用绝对路径。
        if (b.graph.environ_map.get("ANDROID_LIB_DIR")) |lib_dir| {
            if (lib_dir.len > 0) {
                shared_lib.root_module.addLibraryPath(.{ .cwd_relative = lib_dir });
            }
        } else if (android_sysroot) |sysroot| {
            if (b.sysroot != null) {
                // --sysroot 已设置：使用相对路径，链接器会自动拼接 sysroot
                shared_lib.root_module.addLibraryPath(.{
                    .cwd_relative = b.pathJoin(&.{ "usr/lib", arch_name, api_level }),
                });
            } else {
                // 未设置 --sysroot：使用完整绝对路径
                shared_lib.root_module.addLibraryPath(.{
                    .cwd_relative = b.pathJoin(&.{ sysroot, "usr/lib", arch_name, api_level }),
                });
            }
        }

        shared_lib.root_module.linkSystemLibrary("OpenSLES", .{});
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
    android_sysroot: ?[]const u8,
) *std.Build.Module {
    const is_android = target.result.os.tag == .linux and target.result.abi == .android;

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
        if (android_sysroot) |sysroot| {
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
