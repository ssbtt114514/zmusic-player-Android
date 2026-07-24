// miniaudio_wrapper.h
// Android NDK compatibility wrapper for miniaudio

#ifndef MINIAUDIO_WRAPPER_H
#define MINIAUDIO_WRAPPER_H

// Fix for Android NDK nullability attributes
#define _Nonnull
#define _Nullable
#define _Null_unspecified

#include "vendor/miniaudio/miniaudio.h"

#endif