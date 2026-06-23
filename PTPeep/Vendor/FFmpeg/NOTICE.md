# FFmpeg (vendored, decode-only)

PTpeek's video deck decodes in-process with FFmpeg's libraries
(`libavcodec`, `libavformat`, `libavutil`, `libswscale`, `libswresample`).

- **Version:** FFmpeg 8.1.2, built for arm64, macOS 13.0+ deployment target.
- **License:** LGPL v2.1+ (see `COPYING.LGPLv2.1`). This is a **decode-only** build configured
  with `--disable-everything --disable-network --disable-autodetect` and only the decoders/
  demuxers/parsers we need (DNxHD/DNxHR, ProRes, H.264, HEVC, MPEG-2, MJPEG, DV, FFV1; mov/mxf/
  mkv/mpegts/avi demux). No GPL components (no libx264/libx265), no external dependencies.
- **Linking:** the libraries are **dynamically linked** and shipped as separate, replaceable
  dylibs in the app bundle's `Contents/Frameworks/` (install names `@rpath/lib*.dylib`), as LGPL
  requires.

To rebuild these dylibs, see `scratchpad/build_ffmpeg.sh` (the configure invocation used).
