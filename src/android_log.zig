//! Android logcat 日志输出 + JNI 日志回调。
//!
//! 在 Android 上将诊断信息输出到 logcat，便于通过 `adb logcat -s ZMusic` 定位问题。
//! 同时支持通过 JNI 回调将日志输出到 Minecraft 日志（Log4j），无需 adb 即可查看。
//! 非 Android 平台为空操作，不影响桌面构建。
//!
//! 实现说明：`__android_log_print` 是 C variadic 函数，Zig 0.16 对传入 variadic 的
//! 类型有严格限制（不能传 slice、error set、非 2 的幂位宽的整数等）。
//! 因此先用 `std.fmt.bufPrintZ` 在栈上格式化消息，再以 `%s` 格式传入指针，
//! 避免把任意 Zig 类型直接传给 C variadic。

const std = @import("std");
const builtin = @import("builtin");

const ANDROID_LOG_DEBUG: c_int = 3;
const ANDROID_LOG_INFO: c_int = 4;
const ANDROID_LOG_WARN: c_int = 5;
const ANDROID_LOG_ERROR: c_int = 6;

extern fn __android_log_print(prio: c_int, tag: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;

const TAG: [*:0]const u8 = "ZMusic";
const MSG_FMT: [*:0]const u8 = "%s";
const TOO_LONG_MSG: [*:0]const u8 = "[ZMusic] log message too long, truncated";

/// 日志缓冲区大小。1024 字节足以容纳大多数诊断消息；
/// 超出时截断并追加 "..." 标记。
const LOG_BUF_SIZE = 1024;

/// JNI 日志回调函数类型。
/// 由 bridge.zig 在 nativeInit 时设置，用于将日志输出到 Minecraft 日志。
pub const JniLogCallback = *const fn (level: LogLevel, msg: [*:0]const u8) void;

/// 日志级别枚举。
pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    @"error" = 3,
};

/// 全局 JNI 日志回调。为 null 时只输出到 logcat。
var jni_log_callback: ?JniLogCallback = null;

/// 设置 JNI 日志回调。由 bridge.zig 在 nativeInit 时调用。
pub fn setJniLogCallback(cb: ?JniLogCallback) void {
    jni_log_callback = cb;
}

fn writeLog(prio: c_int, comptime fmt: []const u8, args: anytype) void {
    if (builtin.os.tag != .linux or builtin.abi != .android) return;

    var buf: [LOG_BUF_SIZE]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch {
        _ = __android_log_print(prio, TAG, MSG_FMT, TOO_LONG_MSG);
        if (jni_log_callback) |cb| {
            const level: LogLevel = switch (prio) {
                ANDROID_LOG_DEBUG => .debug,
                ANDROID_LOG_INFO => .info,
                ANDROID_LOG_WARN => .warn,
                ANDROID_LOG_ERROR => .@"error",
                else => .info,
            };
            cb(level, TOO_LONG_MSG);
        }
        return;
    };
    _ = __android_log_print(prio, TAG, MSG_FMT, msg.ptr);

    // 同时通过 JNI 回调输出到 Minecraft 日志
    if (jni_log_callback) |cb| {
        const level: LogLevel = switch (prio) {
            ANDROID_LOG_DEBUG => .debug,
            ANDROID_LOG_INFO => .info,
            ANDROID_LOG_WARN => .warn,
            ANDROID_LOG_ERROR => .@"error",
            else => .info,
        };
        cb(level, msg.ptr);
    }
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    writeLog(ANDROID_LOG_DEBUG, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    writeLog(ANDROID_LOG_INFO, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    writeLog(ANDROID_LOG_WARN, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    writeLog(ANDROID_LOG_ERROR, fmt, args);
}
