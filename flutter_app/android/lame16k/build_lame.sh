#!/bin/sh
# Rebuild 16 KB-aligned liblame.so for 64-bit ABIs. The Plaud AAR ships a 4 KB
# page liblame; Android 15+ devices reject that at install.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
if [ -z "$NDK" ]; then
  for candidate in \
    "${ANDROID_HOME:-$HOME/Library/Android/sdk}/ndk/"* \
    /opt/homebrew/share/android-commandlinetools/ndk/*; do
    if [ -d "$candidate" ]; then NDK="$candidate"; fi
  done
fi
if [ ! -d "$NDK" ]; then
  echo "Set ANDROID_NDK_HOME to an NDK r28+ install." >&2
  exit 1
fi
echo "using NDK $NDK"

SRC="$ROOT/lame-3.100"
if [ ! -f "$SRC/libmp3lame/lame.c" ]; then
  ARCHIVE="$ROOT/lame-3.100.tar.gz"
  curl -fsSL -o "$ARCHIVE" \
    "https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz/download"
  tar -xzf "$ARCHIVE" -C "$ROOT"
fi

DEST="$ROOT/../app/src/main/jniLibs"
API=26
for ABI in arm64-v8a x86_64; do
  BUILD="$ROOT/build/$ABI"
  cmake -S "$ROOT" -B "$BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API" \
    -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$BUILD" --target lame
  mkdir -p "$DEST/$ABI"
  cp "$BUILD/liblame.so" "$DEST/$ABI/liblame.so"
  echo "wrote $DEST/$ABI/liblame.so"
done
