#!/bin/bash
set -euo pipefail

WORK="/private/tmp/claude-501/-Users-fozzie-developer-ptpeep/ac7b9135-2bb9-4bf6-88d2-8a66238da43a/scratchpad/ffbuild"
VENDOR="/Users/fozzie/developer/ptpeep/PTPeep/Vendor/FFmpeg"
VER="8.1.2"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -f "ffmpeg-$VER.tar.xz" ]; then
  echo "=== downloading FFmpeg $VER ==="
  curl -fsSL -o "ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
fi
rm -rf "ffmpeg-$VER"
tar xf "ffmpeg-$VER.tar.xz"
cd "ffmpeg-$VER"

echo "=== configure (decode-only, no external deps, @rpath install names) ==="
./configure \
  --prefix="$VENDOR" \
  --enable-shared --disable-static \
  --disable-programs --disable-doc --disable-htmlpages --disable-manpages --disable-txtpages \
  --disable-network --disable-autodetect --disable-debug \
  --disable-everything \
  --enable-protocol=file \
  --enable-demuxer=mov,mxf,matroska,mpegts,avi \
  --enable-parser=h264,hevc,mpeg4video,mpegvideo,dnxhd \
  --enable-decoder=dnxhd,prores,h264,hevc,mpeg2video,mpeg4,mjpeg,dvvideo,ffv1,rawvideo,aac,pcm_s16le,pcm_s24le,pcm_f32le \
  --install-name-dir=@rpath \
  --extra-cflags="-mmacosx-version-min=13.0" \
  --extra-ldflags="-mmacosx-version-min=13.0"

echo "=== make ==="
make -j"$(sysctl -n hw.ncpu)"

echo "=== install into $VENDOR ==="
rm -rf "$VENDOR"
make install

echo "=== result ==="
ls -la "$VENDOR/lib/"*.dylib
echo "=== sizes ==="
du -sh "$VENDOR/lib"
echo "=== install names (should be @rpath) ==="
for l in "$VENDOR"/lib/lib*.*.dylib; do otool -D "$l" | tail -1; done
echo "BUILD_FFMPEG_DONE"
