#ifndef ZMUSIC_MINIAUDIO_WRAPPER_H
#define ZMUSIC_MINIAUDIO_WRAPPER_H

// 绕过 Zig translate-c 对 NDK _Nullable 修饰符用于数组类型时的兼容性问题。
// NDK 的 sys/time.h 中存在类似 `const struct timeval __times[_Nullable 2]` 的写法，
// Zig 0.16.0 的 translate-c 会报错。直接禁用 _Nullable 宏即可，
// miniaudio 不依赖这个宏的语义。
#if defined(__ANDROID__)
    #ifdef _Nullable
        #undef _Nullable
    #endif
    #define _Nullable
#endif

#include "../vendor/miniaudio/miniaudio.h"

#endif // ZMUSIC_MINIAUDIO_WRAPPER_H
