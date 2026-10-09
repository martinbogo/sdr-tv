#!/bin/bash
# libusb and libhackrf as static libraries for macOS 14 and later (Homebrew's are built for the
# macOS they were bottled on), installed into third_party/radio-install. macos/build.sh uses them.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(pwd)/radio-install"
MIN=14.0
USB=1.0.30 HACKRF=2026.01.3
[ -d libusb-$USB ] || { curl -fsSL https://github.com/libusb/libusb/releases/download/v$USB/libusb-$USB.tar.bz2 | tar xj; }
[ -d hackrf-$HACKRF ] || { curl -fsSL https://github.com/greatscottgadgets/hackrf/releases/download/v$HACKRF/hackrf-$HACKRF.tar.xz | tar xJ; }

( cd libusb-$USB
  # pipe2 exists in newer SDKs only: built for macOS 14 it becomes a weak import that is missing at run time
  ./configure --prefix="$OUT" --enable-static --disable-shared --disable-udev ac_cv_func_pipe2=no \
      CFLAGS="-mmacosx-version-min=$MIN -O2 -arch arm64" LDFLAGS="-mmacosx-version-min=$MIN -arch arm64" >/dev/null
  make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )

( cd hackrf-$HACKRF/host/libhackrf
  rm -rf build && mkdir build && cd build
  cmake .. -DCMAKE_INSTALL_PREFIX="$OUT" -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_BUILD_TYPE=Release -DLIBUSB_INCLUDE_DIR="$OUT/include/libusb-1.0" -DLIBUSB_LIBRARIES="$OUT/lib/libusb-1.0.a" >/dev/null
  make -j"$(sysctl -n hw.ncpu)" hackrf_static >/dev/null      # the static library only (the app links it statically)
  mkdir -p "$OUT/lib" "$OUT/include/libhackrf"
  cp ../src/hackrf.h "$OUT/include/libhackrf/"
  cp "$(find . -name 'libhackrf.a' | head -1)" "$OUT/lib/" )
echo "Installed libusb $USB and libhackrf $HACKRF (macOS $MIN+) into $OUT"
