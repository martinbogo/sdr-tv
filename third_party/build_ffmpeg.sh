#!/bin/bash
# Minimal LGPL FFmpeg used by SDR TV: decoders for ATSC 1.0 video/audio and the deinterlacer.
set -euo pipefail
cd "$(dirname "$0")"
V=7.1.1
[ -d ffmpeg-$V ] || { curl -fsSL -o ffmpeg-$V.tar.xz https://ffmpeg.org/releases/ffmpeg-$V.tar.xz; tar xf ffmpeg-$V.tar.xz; }
cd ffmpeg-$V
./configure --prefix="$(cd .. && pwd)/ffmpeg-install" \
  --enable-static --disable-shared --disable-programs --disable-doc --disable-network --disable-autodetect \
  --disable-everything --disable-avformat --disable-avdevice \
  --enable-avcodec --enable-avfilter --enable-swscale --enable-swresample \
  --enable-decoder=mpeg2video,mpeg1video,h264,hevc,ac3,eac3,aac,aac_latm,mp2,mp3 \
  --enable-parser=mpegvideo,h264,hevc,ac3,aac,aac_latm,mpegaudio \
  --enable-filter=bwdif,yadif,buffer,buffersink,format,scale,null \
  --arch=arm64 --cc=clang --extra-cflags="-mmacosx-version-min=14.0 -O3" --extra-ldflags="-mmacosx-version-min=14.0"
make -j"$(sysctl -n hw.ncpu)"
make install
