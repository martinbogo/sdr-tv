#!/bin/bash
# Builds "SDR TV.app": a self-contained Apple Silicon app with the 8VSB receiver (C),
# a minimal LGPL FFmpeg, libhackrf and libusb all linked statically.
#   Requires: Xcode command line tools, `brew install hackrf`, and third_party/ffmpeg-install
#   (see ../third_party/build_ffmpeg.sh).
set -euo pipefail
cd "$(dirname "$0")"

BREW="$(brew --prefix)"
FF="../third_party/ffmpeg-install"
APP="build/SDR TV.app"
OBJ="build/obj"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

# C signal processing and media (portable across Apple Silicon: target the M1 baseline)
clang -c -O3 -mcpu=apple-m1 -ffast-math -mmacosx-version-min=14.0 -o "$OBJ/atsc_rx.o" ../dsp/atsc_rx.c
clang -c -O2 -mcpu=apple-m1 -mmacosx-version-min=14.0 -I"$FF/include" -o "$OBJ/atsc_media.o" ../dsp/atsc_media.c
clang -c -O2 -mcpu=apple-m1 -mmacosx-version-min=14.0 -o "$OBJ/atsc_captions.o" ../dsp/atsc_captions.c

swiftc -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macos14.0 \
    -import-objc-header Sources/Bridging.h -I "$BREW/include" \
    Sources/*.swift \
    "$OBJ/atsc_rx.o" "$OBJ/atsc_media.o" "$OBJ/atsc_captions.o" \
    "$FF/lib/libavfilter.a" "$FF/lib/libswscale.a" "$FF/lib/libswresample.a" "$FF/lib/libavcodec.a" "$FF/lib/libavutil.a" \
    "$BREW/lib/libhackrf.a" "$BREW/lib/libusb-1.0.a" \
    -framework Accelerate -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -framework VideoToolbox -framework IOKit -framework CoreFoundation -framework Security \
    -o "$APP/Contents/MacOS/SDR TV"

cp Info.plist "$APP/Contents/Info.plist"
swift make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset
mkdir -p "$APP/Contents/Resources/Licenses"
cp ../LICENSE ../THIRD_PARTY_NOTICES.md ../licenses/* "$APP/Contents/Resources/Licenses/" 2>/dev/null || true

codesign --force --sign - "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
(cd build && ditto -c -k --keepParent "SDR TV.app" "SDR-TV-$VERSION-macOS-arm64.zip")
echo "Built $APP"

# ./build.sh --install runs tests/run.sh, then copies the app into /Applications and registers it with Launch Services
if [ "${1:-}" = "--install" ]; then
    # regression checks first: a build that makes reception, decoding or the channel list worse is not installed
    ../tests/run.sh || { echo "Not installed: regression checks failed (SKIP_TESTS=1 to override)"; [ "${SKIP_TESTS:-}" = 1 ] || exit 1; }
    osascript -e 'quit app "SDR TV"' 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/SDR TV.app"
    ditto "$APP" "/Applications/SDR TV.app"
    xattr -dr com.apple.quarantine "/Applications/SDR TV.app" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/SDR TV.app"
    touch "/Applications/SDR TV.app"
    echo "Installed /Applications/SDR TV.app"
fi
