# Timecode-Synced Video Playback on macOS — Engineering Handoff

**From:** the Walter project (a macOS flatbed film-editor app)
**For:** a Pro Tools–focused project browser that wants to bolt on a timecode-synced video preview deck
**Scope:** everything we learned shipping frame-accurate video playback on macOS, with a heavy focus on **Avid DNxHD/DNxHR (the "Apple Pro Video Formats" / MXF) integration**, plus the **audio extraction + timecode-sync** model you'll need to scrub video against a Pro Tools session.

> This document is written to be ingested directly by Claude (or any LLM coding assistant). It is deliberately code-heavy and self-contained so your assistant doesn't have to re-derive any of this. All Swift excerpts are real, lightly trimmed, and annotated. File names refer to Walter's tree but the patterns are portable.

---

## 0. The one thing to take away

**Do not decode DNxHD/DNxHR through AVFoundation/VideoToolbox if you care about launch latency.** Apple ships a DNx decoder ("Pro Video Formats"), but it lives in a sandboxed XPC helper (`VTDecoderXPCService`). On a cold app launch, the first DNx decode session blocks for **~40 seconds** while macOS spins that helper up — and every other VideoToolbox call in your process queues behind it. We measured this repeatedly.

The fix that made Walter usable: **decode DNx in-process with libavcodec (FFmpeg) and bypass VideoToolbox entirely.** Cold-start time-to-first-frame on a 2K DNxHD MXF on an M1 Max dropped from **~40,000 ms → ~33 ms** (about 1,200×). Steady-state libav decode is **~1.6 ms/frame** (~26× real-time at 24 fps), so you don't even need a hardware decoder or a fancy prefetch pool to hit smooth playback.

Everything below is how to build that, plus the ProRes/H.264 path (which AVFoundation *does* handle well), the routing logic that picks between them, the frame cache, the timecode plumbing, audio, and the rendering hand-off.

---

## 1. Architecture at a glance

Two decoders behind one interface, picked **by codec, not by file extension**:

```
                    ┌──────────────────────────────────────┐
   source URL  ───► │  FrameCacheManager.addSource(url)     │
                    │  routes by codec                      │
                    └───────────────┬──────────────────────┘
                                    │
              .mxf  OR  DNx-in-.mov │  everything else
              (sniff the FourCC)    │  (ProRes, H.264, HEVC, MP4…)
                                    │
                ┌───────────────────┴───────────────────┐
                ▼                                        ▼
   ┌────────────────────────┐              ┌────────────────────────────┐
   │ LibavDecoder           │              │ ProResDecoder              │
   │ libavformat + libavcodec│             │ AVFoundation (AVAssetReader)│
   │ + libswscale → BGRA     │             │ native pixel formats        │
   └───────────┬────────────┘              └──────────────┬─────────────┘
               │                                          │
   ┌───────────▼────────────┐              ┌──────────────▼─────────────┐
   │ LibavFrameCache         │             │ FrameCache (+ prefetch pool)│
   │ (minimal, inline decode)│             └──────────────┬─────────────┘
   └───────────┬────────────┘                             │
               └──────────────────┬───────────────────────┘
                                  ▼
                  CVPixelBuffer  ──►  Metal renderer (CVMetalTextureCache)
```

Both decoders expose the **same public surface** so the cache manager can swap one for the other per-source:

| Property / method | Meaning |
|---|---|
| `static func make(url:) async -> Self?` | Async factory; returns nil if the file can't be opened/decoded |
| `totalFrames: Int` | Frame count |
| `fps: Double` | Frame rate |
| `dimensions: CGSize` | Pixel dimensions |
| `duration: CMTime` | Duration |
| `startTimecodeFrames: Int?` | Embedded start TC as **frame count from midnight** (nil if none) |
| `reelName: String` | Reel/tape name from metadata, else filename stem |
| `func decodeSample(at index: Int) -> CMSampleBuffer?` | Decode one frame → `CMSampleBuffer` wrapping a BGRA (or biplanar) `CVPixelBuffer` |

Keep that table as your contract. If you build only one decoder, build the libav one — it covers DNx *and* (if you want) everything else.

---

## 2. Build setup — linking FFmpeg into a Swift/Xcode app

This is the part people get stuck on, so it's first. You bridge Swift → FFmpeg's C libraries with a tiny **system library module**. No subprocess, no shelling out to the `ffmpeg` binary.

### 2.1 Install FFmpeg (provides the dylibs + headers)

```sh
brew install ffmpeg
```

Homebrew drops `.pc` (pkg-config) files at `/opt/homebrew/lib/pkgconfig/`, which is how SwiftPM finds the headers and libs without you hard-coding paths. **The end user needs the FFmpeg libs present too** (or you bundle/static-link them — see §12 on LGPL).

### 2.2 The C bridge — three small files

**`Sources/CFFmpeg/module.modulemap`**
```
module CFFmpeg [system] {
    header "shim.h"
    link "avcodec"
    link "avformat"
    link "avutil"
    link "swscale"
    link "swresample"
    export *
}
```

**`Sources/CFFmpeg/shim.h`** — an umbrella header listing exactly the FFmpeg headers you call into. Keep it narrow; pulling in everything slows module rebuilds.
```c
#ifndef WALTER_CFFMPEG_SHIM_H
#define WALTER_CFFMPEG_SHIM_H

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/error.h>
#include <libavutil/timestamp.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/samplefmt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>

#endif
```

**`Package.swift`** — declare the system library with `pkgConfig`, then depend on it from your app target:
```swift
.executableTarget(
    name: "YourApp",
    dependencies: ["CFFmpeg"],
    // …
),
.systemLibrary(
    name: "CFFmpeg",
    path: "Sources/CFFmpeg",
    pkgConfig: "libavcodec libavformat libavutil libswscale libswresample",
    providers: [.brew(["ffmpeg"])]
),
```

After this, `import CFFmpeg` in any Swift file gives you `avformat_open_input`, `avcodec_send_packet`, `sws_scale`, etc. as plain Swift calls.

> **Xcode (non-SwiftPM) note:** if you're not on SwiftPM, you replicate this with a bridging header (or a module map added to `SWIFT_INCLUDE_PATHS`) plus `OTHER_LDFLAGS = $(shell pkg-config --libs libavcodec …)` or explicit `-L/opt/homebrew/lib -lavcodec -lavformat -lavutil -lswscale -lswresample`. The module-map route is cleaner and is what we'd recommend.

### 2.3 Two FFmpeg-version gotchas that will bite you

These changed between FFmpeg releases and the Swift importer surfaces them differently:

- **`SwsContext`** — older FFmpeg imported it as `OpaquePointer?`; FFmpeg 8.1+ exposes it as a real struct, so Swift imports `UnsafeMutablePointer<SwsContext>?`. Declare your `swsCtx` var accordingly for your installed version.
- **`SWS_BILINEAR`** — on FFmpeg 8.1 this imports as a `SwsFlags` option-set value, not a bare `Int`. Pass `Int32(SWS_BILINEAR.rawValue)` to `sws_getContext`.
- **`AVERROR(EAGAIN)` / `AVERROR_EOF`** are C macros and are **invisible to Swift**. Redeclare the numeric values yourself (see §3.4).

---

## 3. The libav decoder (the DNx path) — full walkthrough

This is `LibavDecoder.swift`. It's `@unchecked Sendable`; every decode path takes an `NSLock` because a libavcodec context is **not** thread-safe per instance. For prefetch parallelism you build N decoders against the same URL, exactly like you'd pool AVAssetReaders.

### 3.1 Open the file, find the streams, open the codec (the async factory)

```swift
import CoreMedia
import CoreVideo
import Foundation
import CFFmpeg

final class LibavDecoder: @unchecked Sendable {
    let sourceURL: URL
    let totalFrames: Int
    let fps: Double
    let dimensions: CGSize
    let duration: CMTime
    let startTimecodeFrames: Int?   // frames from midnight, nil if no TC
    let reelName: String
    // … plus rich MXF slate metadata: scene/take/camera/camroll/soundroll/shootDate/comments

    private let lock = NSLock()
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private let videoStreamIndex: Int32
    private let streamTimeBase: AVRational
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var swsCtx: UnsafeMutablePointer<SwsContext>?
    private var currentFrameIndex: Int = -1   // -1 = nothing decoded yet / post-flush

    static func make(url: URL) async -> LibavDecoder? {
        // 1. Open input
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&formatCtx, url.path, nil, nil) == 0, formatCtx != nil else {
            return nil
        }
        // Any early return from here must avformat_close_input(&formatCtx).

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            avformat_close_input(&formatCtx); return nil
        }

        // 2. First video stream + first audio stream (if any)
        let nStreams = Int(formatCtx!.pointee.nb_streams)
        var videoStreamIdx: Int32 = -1
        var audioStreamIdx: Int32 = -1
        for i in 0..<nStreams {
            guard let stream = formatCtx!.pointee.streams[i] else { continue }
            let type = stream.pointee.codecpar.pointee.codec_type
            if type == AVMEDIA_TYPE_VIDEO && videoStreamIdx < 0 { videoStreamIdx = Int32(i) }
            else if type == AVMEDIA_TYPE_AUDIO && audioStreamIdx < 0 { audioStreamIdx = Int32(i) }
        }
        guard videoStreamIdx >= 0 else { avformat_close_input(&formatCtx); return nil }

        let videoStream = formatCtx!.pointee.streams[Int(videoStreamIdx)]!
        let codecpar = videoStream.pointee.codecpar!

        // 3. Find + open the decoder for this codec_id (DNx, ProRes, H.264, … all just work)
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            avformat_close_input(&formatCtx); return nil
        }
        guard let codecCtx = avcodec_alloc_context3(codec) else {
            avformat_close_input(&formatCtx); return nil
        }
        var codecCtxLocal: UnsafeMutablePointer<AVCodecContext>? = codecCtx
        guard avcodec_parameters_to_context(codecCtxLocal, codecpar) >= 0 else {
            avcodec_free_context(&codecCtxLocal); avformat_close_input(&formatCtx); return nil
        }
        // Frame + slice threading, auto worker count — this is what gets you 26× real-time.
        codecCtxLocal!.pointee.thread_count = 0
        codecCtxLocal!.pointee.thread_type = Int32(FF_THREAD_FRAME | FF_THREAD_SLICE)
        guard avcodec_open2(codecCtxLocal, codec, nil) == 0 else {
            avcodec_free_context(&codecCtxLocal); avformat_close_input(&formatCtx); return nil
        }

        // 4. Reusable packet + frame
        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else {
            avcodec_free_context(&codecCtxLocal); avformat_close_input(&formatCtx); return nil
        }

        // 5. fps / frame count / duration (see §3.2) and metadata (see §3.5) …
        //    then hand everything to a private sync init.
    }
}
```

### 3.2 Frame count, fps, duration — get the rounding right

29.97/23.976 will lose frames if you truncate. Prefer the muxer's authoritative `nb_frames` (MXF always writes it), fall back to `duration * fps` **rounded**.

```swift
let timeBase = videoStream.pointee.time_base
let avgFR = videoStream.pointee.avg_frame_rate
let rFR   = videoStream.pointee.r_frame_rate
let fps: Double =
    (avgFR.num > 0 && avgFR.den > 0) ? Double(avgFR.num) / Double(avgFR.den) :
    (rFR.num   > 0 && rFR.den   > 0) ? Double(rFR.num)   / Double(rFR.den)   : 24.0

let streamFrames = videoStream.pointee.nb_frames
let durationSec: Double =
    formatCtx!.pointee.duration > 0 ? Double(formatCtx!.pointee.duration) / Double(AV_TIME_BASE) :
    videoStream.pointee.duration > 0 ? Double(videoStream.pointee.duration) * Double(timeBase.num) / Double(timeBase.den) : 0
let totalFrames: Int =
    streamFrames > 0 ? Int(streamFrames) :
    durationSec  > 0 ? Int((durationSec * fps).rounded()) : 0
```

### 3.3 Decoding a specific frame — seek + decode-forward loop

The public entry point. DNx is **all-intra** (every frame is a keyframe), so a seek lands you exactly where you ask — no GOP rewind. The 60-frame "skip ahead vs. re-seek" threshold matches the ProRes path so the surrounding cache tuning behaves identically.

```swift
func decodeSample(at index: Int) -> CMSampleBuffer? {
    lock.lock(); defer { lock.unlock() }
    guard index >= 0, index < totalFrames else { return nil }
    guard formatCtx != nil, codecCtx != nil, packet != nil, frame != nil else { return nil }

    // Seek if we're behind, or far ahead.
    if currentFrameIndex < 0 || index < currentFrameIndex || index > currentFrameIndex + 60 {
        seekLocked(to: index)
    }

    // Decode forward until currentFrameIndex == index.
    var safety = 0
    while currentFrameIndex < index {
        guard decodeOneFrameLocked() else { return nil }   // EOF/error
        safety += 1
        if safety > totalFrames + 100 { return nil }       // defensive
    }
    return makeSampleBufferLocked(frameIndex: index)        // → BGRA CVPixelBuffer
}

private func seekLocked(to index: Int) {
    guard let formatCtx = formatCtx, let codecCtx = codecCtx else { return }
    let pts = ptsForFrame(index)
    av_seek_frame(formatCtx, videoStreamIndex, pts, AVSEEK_FLAG_BACKWARD)
    avcodec_flush_buffers(codecCtx)
    currentFrameIndex = index - 1   // decode loop advances 1 at a time to land on index
}

/// Convert a 0-based frame index → PTS in the stream's time base, precisely (handles 23.976/29.97).
private func ptsForFrame(_ index: Int) -> Int64 {
    let videoStream = formatCtx!.pointee.streams[Int(videoStreamIndex)]!
    let avgFR = videoStream.pointee.avg_frame_rate
    let rFR   = videoStream.pointee.r_frame_rate
    let frameRate: AVRational =
        (avgFR.num > 0 && avgFR.den > 0) ? avgFR :
        (rFR.num   > 0 && rFR.den   > 0) ? rFR   : AVRational(num: 24, den: 1)
    // frame_duration in timebase units = (frameRate.den / frameRate.num) / streamTimeBase
    return av_rescale_q(Int64(index),
                        AVRational(num: frameRate.den, den: frameRate.num),
                        streamTimeBase)
}
```

The packet→frame pump. Note the EAGAIN/EOF handling and the flush-at-EOF (`send_packet(nil)`):

```swift
private func decodeOneFrameLocked() -> Bool {
    guard let formatCtx = formatCtx, let codecCtx = codecCtx,
          let packet = packet, let frame = frame else { return false }
    while true {
        let recvStatus = avcodec_receive_frame(codecCtx, frame)
        if recvStatus == 0 { currentFrameIndex += 1; return true }
        if recvStatus != Self.AVERROR_EAGAIN { return false }   // EOF or hard error

        let readStatus = av_read_frame(formatCtx, packet)
        if readStatus < 0 {                       // EOF → flush decoder, loop to drain
            avcodec_send_packet(codecCtx, nil); continue
        }
        defer { av_packet_unref(packet) }
        if packet.pointee.stream_index != videoStreamIndex { continue }
        let sendStatus = avcodec_send_packet(codecCtx, packet)
        if sendStatus < 0 && sendStatus != Self.AVERROR_EAGAIN { return false }
    }
}
```

### 3.4 The AVERROR constant shims

```swift
// AVERROR(EAGAIN) and AVERROR_EOF are C macros — not visible to Swift. Redeclare:
private static let AVERROR_EAGAIN: Int32 = -35           // -EAGAIN on macOS (EAGAIN == 35)
private static let AVERROR_EOF:    Int32 = -541478725    // FFERRTAG('E','O','F',' ')
```

### 3.5 Metadata — reel name, timecode, and (bonus) the full MXF slate

This is a **big reason to use libav for MXF**: `AVAssetReader` surfaces almost none of the OP-Atom metadata graph, but libavformat reads all of it. For a Pro Tools browser this is gold — you get scene/take/camera/camroll/soundroll/shoot-date straight off the clip.

```swift
private func dictGet(_ dict: OpaquePointer?, key: String) -> String? {
    guard let dict = dict, let entry = av_dict_get(dict, key, nil, 0) else { return nil }
    return String(cString: entry.pointee.value)
}

let formatMeta = formatCtx!.pointee.metadata
let streamMeta = videoStream.pointee.metadata

// Reel/tape name
let reelName = dictGet(streamMeta, key: "reel_name")
    ?? dictGet(formatMeta, key: "material_package_name")
    ?? url.deletingPathExtension().lastPathComponent

// Start timecode: libavformat gives "HH:MM:SS:FF" or drop-frame "HH:MM:SS;FF".
let tcString = dictGet(streamMeta, key: "timecode") ?? dictGet(formatMeta, key: "timecode")
let startTimecodeFrames = tcString.flatMap { parseTimecodeToFrames($0, fps: fps) }

// Avid MXF "comment" metadata normalizes to comment_<Name> keys:
let scene      = dictGet(formatMeta, key: "comment_Scene")
let take       = dictGet(formatMeta, key: "comment_Take")
let camera     = dictGet(formatMeta, key: "comment_Camera")
let camroll    = dictGet(formatMeta, key: "comment_Camroll")
let soundroll  = dictGet(formatMeta, key: "comment_Soundroll")
let shootDate  = dictGet(formatMeta, key: "comment_Shoot Date")
let comments   = dictGet(formatMeta, key: "comment_Comments")
```

Timecode string → frame count from midnight:

```swift
/// "HH:MM:SS:FF" (or drop-frame "HH:MM:SS;FF") → frames from midnight.
/// NOTE: we intentionally do NOT apply drop-frame compensation — Walter uses
/// the count for relative offsets where drop vs. non-drop is a wash. If you
/// need true wall-clock DF math, handle the ';' case specially.
private func parseTimecodeToFrames(_ tc: String, fps: Double) -> Int? {
    let normalized = tc.replacingOccurrences(of: ";", with: ":")
    let parts = normalized.split(separator: ":").map(String.init)
    guard parts.count == 4,
          let h = Int(parts[0]), let m = Int(parts[1]),
          let s = Int(parts[2]), let f = Int(parts[3]) else { return nil }
    let fpsInt = Int(fps.rounded())
    return ((h * 3600 + m * 60 + s) * fpsInt) + f
}
```

> ⚠️ **Drop-frame:** if your Pro Tools sessions run 29.97 DF and you need exact session-time ↔ frame mapping, replace the naive `parseTimecodeToFrames` with proper drop-frame math (drop 2 frames every minute except every 10th). Walter skips it because it only needs relative offsets. You probably need it. See §9.

### 3.6 Frame → `CVPixelBuffer` via `sws_scale` (BGRA, Metal-ready)

The decoded `AVFrame` is in the codec's native planar YUV. We convert to **BGRA** with libswscale into a Metal-compatible `CVPixelBuffer`, then wrap it in a `CMSampleBuffer`. One `SwsContext` is cached per decoder and only rebuilt on format/size change (never happens mid-file for OP-Atom MXF).

```swift
private func makeSampleBufferLocked(frameIndex: Int) -> CMSampleBuffer? {
    guard let frame = frame else { return nil }
    let srcW = Int(frame.pointee.width), srcH = Int(frame.pointee.height)
    let srcFormat = frame.pointee.format
    guard srcW > 0, srcH > 0 else { return nil }

    // Draft mode (smoother shuttle): half-size the OUTPUT; decode stays full-res
    // because libavcodec has no free half-decode path.
    let outW = draftMode ? max(srcW / 2, 16) : srcW
    let outH = draftMode ? max(srcH / 2, 16) : srcH

    if swsCtx == nil || swsCachedSrcFormat != srcFormat || swsCachedSize != (outW, outH) {
        if let existing = swsCtx { sws_freeContext(existing) }
        swsCtx = sws_getContext(Int32(srcW), Int32(srcH), AVPixelFormat(rawValue: srcFormat),
                                Int32(outW), Int32(outH), AV_PIX_FMT_BGRA,
                                Int32(SWS_BILINEAR.rawValue), nil, nil, nil)   // FFmpeg 8.1: .rawValue
        swsCachedSrcFormat = srcFormat; swsCachedSize = (outW, outH)
        guard swsCtx != nil else { return nil }
    }

    // Destination CVPixelBuffer — IOSurface-backed + Metal-compatible.
    var pixelBuffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, outW, outH,
                              kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
          let pb = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let dstBase = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let dstStride = CVPixelBufferGetBytesPerRow(pb)

    // AVFrame.data/.linesize are 8-tuples in Swift — splat into arrays with stable addresses.
    var srcSlices: [UnsafePointer<UInt8>?] = [
        UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
        UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3),
        UnsafePointer(frame.pointee.data.4), UnsafePointer(frame.pointee.data.5),
        UnsafePointer(frame.pointee.data.6), UnsafePointer(frame.pointee.data.7),
    ]
    var srcStrides: [Int32] = [
        frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2, frame.pointee.linesize.3,
        frame.pointee.linesize.4, frame.pointee.linesize.5, frame.pointee.linesize.6, frame.pointee.linesize.7,
    ]
    var dstSlices: [UnsafeMutablePointer<UInt8>?] = [dstBase.assumingMemoryBound(to: UInt8.self),
                                                     nil, nil, nil, nil, nil, nil, nil]
    var dstStrides: [Int32] = [Int32(dstStride), 0, 0, 0, 0, 0, 0, 0]

    _ = sws_scale(swsCtx, &srcSlices, &srcStrides, 0, Int32(srcH), &dstSlices, &dstStrides)

    // Wrap the CVPixelBuffer in a CMSampleBuffer (timing derived from frame index).
    var formatDesc: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pb, formatDescriptionOut: &formatDesc) == noErr,
          let formatDesc = formatDesc else { return nil }

    var timing = CMSampleTimingInfo(
        duration: CMTime(seconds: 1.0 / fps, preferredTimescale: 1_000_000),
        presentationTimeStamp: CMTime(seconds: Double(frameIndex) / fps, preferredTimescale: 1_000_000),
        decodeTimeStamp: .invalid)

    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pb, formatDescription: formatDesc,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr else { return nil }
    return sampleBuffer
}
```

### 3.7 Teardown — free everything in `deinit`

```swift
deinit {
    if let swsCtx { sws_freeContext(swsCtx) }
    if packet  != nil { av_packet_free(&packet) }
    if frame   != nil { av_frame_free(&frame) }
    if codecCtx != nil { avcodec_free_context(&codecCtx) }
    if formatCtx != nil { avformat_close_input(&formatCtx) }
}
```

**That's the entire DNx playback path.** If all you want is "play DNxHD/DNxHR MXF in-process with frame-accurate seeking," sections 2–3 are sufficient. The rest is polish (the AVFoundation path, caching, audio, sync).

---

## 4. The AVFoundation decoder (ProRes / H.264 / HEVC / MP4)

For non-DNx codecs, AVFoundation is the right tool — it's hardware-accelerated and you don't fight XPC cold-start. `ProResDecoder` wraps `AVAssetReader`. Two things worth lifting:

### 4.1 Async factory (macOS 13+ deprecated the sync property accessors)

`AVAsset.duration`, `loadTracks(...)`, `AVAssetTrack.naturalSize/.nominalFrameRate/.formatDescriptions/.metadata` are all deprecated-sync now. Fan them out with `async let`:

```swift
static func make(url: URL) async -> ProResDecoder? {
    let asset = AVAsset(url: url)
    async let durFuture      = asset.load(.duration)
    async let vTracksFuture  = asset.loadTracks(withMediaType: .video)
    async let aTracksFuture  = asset.loadTracks(withMediaType: .audio)
    async let tcTracksFuture = asset.loadTracks(withMediaType: .timecode)
    async let metaFuture     = asset.load(.metadata)
    // … await all, guard videoTracks.first, then load per-track props the same way …
}
```

### 4.2 Native pixel-format selection — the ProRes/DNx "biplanar" trick

This is the single most important performance lever on the AVFoundation side. If you let `AVAssetReader` hand you BGRA, it sneaks in a hidden `VTPixelTransferSession` with a generic Rec.709 matrix — CPU-slow. Instead, **request the codec's native 10-bit 4:2:2 biplanar layout** and let your Metal shader do YCbCr→RGB. ProRes 422 *and* 10-bit DNx share this layout.

```swift
// ProRes 422 family FourCCs:
let apch: CMVideoCodecType = 0x61706368   // ProRes 422 HQ
let apcn: CMVideoCodecType = 0x6170636E   // ProRes 422
let apcs: CMVideoCodecType = 0x61706373   // ProRes 422 LT
let apco: CMVideoCodecType = 0x6170636F   // ProRes 422 Proxy
// Avid DNx families (when decoded via AVFoundation rather than libav):
let avdh: CMVideoCodecType = 0x41566468   // 'AVdh' — DNxHR
let avdn: CMVideoCodecType = 0x4156646E   // 'AVdn' — DNxHD

let preferredFormat: OSType = (isProRes422(codec) || isDNx422(codec))
    ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    : kCVPixelFormatType_32BGRA

var outputSettings: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: preferredFormat,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    kCVPixelBufferMetalCompatibilityKey as String: true,
]
var output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
output.alwaysCopiesSampleData = false

// 8-bit DNx variants (DNxHR LB/SQ, DNxHD SQ/LB) won't satisfy the 10-bit layout —
// canAdd() returns false; fall back to BGRA. The renderer handles either.
if !reader.canAdd(output) && preferredFormat != kCVPixelFormatType_32BGRA {
    outputSettings[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
    output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
}
```

> You *can* play DNx this way. We don't, because of the §0 cold-start tax. But the native-format trick is exactly why the renderer in §8 has a biplanar branch — ProRes still uses it.

### 4.3 Start timecode from the AVFoundation timecode track

A one-frame read off the `.timecode` track; the value is a big-endian frame count:

```swift
if let tcTrack = timecodeTracks.first, let tcReader = try? AVAssetReader(asset: asset) {
    let tcOutput = AVAssetReaderTrackOutput(track: tcTrack, outputSettings: nil)
    if tcReader.canAdd(tcOutput) {
        tcReader.add(tcOutput); tcReader.startReading()
        if let sb = tcOutput.copyNextSampleBuffer(),
           let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &len, dataPointerOut: &ptr)
            if let ptr, len >= 4 {
                startTimecodeFrames = ptr.withMemoryRebound(to: Int32.self, capacity: 1) {
                    Int(Int32(bigEndian: $0.pointee))
                }
            }
        }
        tcReader.cancelReading()
    }
}
```

Net effect: **both decoders give you `startTimecodeFrames` in the same units** (frames from midnight), so downstream code never branches on backend.

---

## 5. Routing — pick the decoder by codec, not extension

`.mxf` is always DNx → libav, unconditionally. But DNx also ships inside **QuickTime/MP4** ("DNxHD QuickTime" exports from Resolve/Premiere). Those `.mov`s are opaque until you read the video track's FourCC, so **sniff** them and route DNx essence to libav too — otherwise they fall through to AVFoundation and eat the cold-start.

```swift
func addSource(url: URL) async -> ProResDecoder? {
    let canonical = url.standardizedFileURL
    // … idempotency / in-flight guards under a lock …

    let ext = canonical.pathExtension.lowercased()
    let isMXF = ext == "mxf"

    var sniffedDNx = false
    if !isMXF, ["mov", "mp4", "m4v", "qt"].contains(ext) {   // ambiguous containers only
        sniffedDNx = await containsDNxVideo(canonical)        // reads track FourCC, checks AVdh/AVdn
    }

    if isMXF || sniffedDNx {
        guard let libav = await LibavDecoder.make(url: canonical) else { return nil }
        let cache = LibavFrameCache(decoder: libav)
        // register libavDecoders[canonical] = libav; libavCaches[canonical] = cache
        cache.primePrefetch(around: 0)
        return nil   // libav-backed sources don't return a ProResDecoder; callers use totalFrames(for:)
    }

    if let decoder = await ProResDecoder.make(url: canonical) {
        let cache = FrameCache(decoder: decoder)
        // register decoders[canonical] = decoder; caches[canonical] = cache
        return decoder
    }
    return nil
}
```

The manager keeps **parallel dictionaries** (`libavDecoders`/`libavCaches` and `decoders`/`caches`) and every read tries libav first, then ProRes. A URL is only ever in one path, so it's a single-hit lookup:

```swift
func frame(at index: Int, from url: URL) -> CVPixelBuffer? {
    let canonical = url.standardizedFileURL
    // (lock, snapshot the two caches, unlock — never hold the manager lock across a decode)
    if let libav = libavCaches[canonical] { return libav.frame(at: index) }
    if let cache = caches[canonical]      { return cache.frame(at: index) }
    return nil
}
```

Metadata reads unify the same way, so exporters/UI see one shape:

```swift
struct SourceMetadata { let reelName: String; let startTimecodeFrames: Int?
                        let dimensions: CGSize; let totalFrames: Int }

func startTimecodeFrames(for url: URL) -> Int? {
    let c = url.standardizedFileURL
    return libavDecoders[c]?.startTimecodeFrames ?? decoders[c]?.startTimecodeFrames
}
```

---

## 6. Frame cache & prefetch — and why the DNx one is *simpler*

Decode cost dictates cache complexity:

- **ProRes/H.264 (`FrameCache`)** — needs a real prefetch **worker pool** (multiple decoders per source) because AVAssetReader decode + the occasional VT hiccup can blow the per-frame budget during fast shuttle.
- **DNx (`LibavFrameCache`)** — libav decodes at **~1.6 ms/frame** vs. a **41 ms** budget at 24 fps. That's 25× headroom; even at 3× shuttle you've got ~13 ms of slack against 1.6 ms. So the DNx cache is just a **`[Int: CMSampleBuffer]` dictionary + inline decode on miss + a single rolling prefetch Task + windowed eviction.** No pool.

Key behaviors of `LibavFrameCache` worth copying:

```swift
final class LibavFrameCache: @unchecked Sendable {
    private let decoder: LibavDecoder
    private var cache: [Int: CMSampleBuffer] = [:]
    private let cacheLock = NSLock()
    private let baseCacheRadius = 30           // ±30 frames ≈ ±1.25 s at 24 fps
    var speedMultiplier: Double = 1.0          // widen window during fast shuttle

    // Blocking: exact hit → return; miss → decode inline (1.6 ms), insert, evict, prefetch.
    func frame(at index: Int) -> CVPixelBuffer? { /* … */ }

    // Non-blocking (motion path): exact hit → return; else nearest cached frame
    // within a small radius (behind-first, since forward motion keeps recent frames);
    // else decode inline. Never returns nil mid-motion if it can help it.
    func cachedFrame(at index: Int) -> CVPixelBuffer? { /* … */ }
}
```

The rolling prefetch uses a **generation counter** instead of per-task cancellation tokens: bump `prefetchGeneration` on scrub/invalidate/focus-loss; the worker re-checks it before each decode and exits cleanly when overtaken. Re-trigger is gated (`movedFar || !prefetchInFlight`) so a monotonic forward playhead doesn't spawn a new Task every tick.

```swift
private func triggerPrefetch(around index: Int) {
    cacheLock.lock()
    let movedFar = abs(index - lastPrefetchAnchor) > (baseCacheRadius / 2)
    guard movedFar || !prefetchInFlight else { cacheLock.unlock(); return }
    prefetchGeneration &+= 1; let gen = prefetchGeneration
    lastPrefetchAnchor = index; prefetchInFlight = true
    cacheLock.unlock()

    let radius = Int(Double(baseCacheRadius) * max(1.0, speedMultiplier))
    let endIndex = min(decoder.totalFrames - 1, index + radius)
    Task.detached(priority: .utility) { [weak self] in
        guard let self else { return }
        var i = index + 1
        while i <= endIndex {
            self.cacheLock.lock()
            if self.prefetchGeneration != gen { self.prefetchInFlight = false; self.cacheLock.unlock(); return }
            let already = self.cache[i] != nil
            self.cacheLock.unlock()
            if !already, let s = self.decoder.decodeSample(at: i) {
                self.cacheLock.lock(); self.cache[i] = s; self.cacheLock.unlock()
            }
            i += 1
        }
        self.cacheLock.lock(); if self.prefetchGeneration == gen { self.prefetchInFlight = false }; self.cacheLock.unlock()
    }
}
```

Eviction keeps a window around the playhead (`keepRadius` scales with speed) and is throttled so it doesn't run every frame. For your use case — scrubbing to arbitrary timecodes — the dictionary + nearest-frame fallback is exactly what keeps the viewer from flashing black while the exact frame decodes.

---

## 7. Pull-based playback model (how the viewer gets frames)

Walter is **pull-based**, not push: the renderer, driven by a `CVDisplayLink`, reads `monitoredDeck.currentFrame` every vsync and draws it. The transport just updates a playhead position; nothing imperatively "displays" a frame. This decouples decode from display and means a slow decode degrades to "hold last frame" instead of stuttering the UI thread.

For a timecode-synced preview that's the model you want:

1. Something (your Pro Tools session scanner / playhead) produces a **target timecode** continuously.
2. You convert TC → source frame index (§9).
3. The render loop pulls `cache.cachedFrame(at: index)` each vsync — non-blocking, nearest-frame fallback.
4. A background prefetch keeps the window ahead of the playhead warm.

Use `CVDisplayLink` (not a `Timer`) so you're synced to the actual display refresh.

---

## 8. Rendering the `CVPixelBuffer` (Metal)

The renderer (`FilmGateRenderer`) turns a `CVPixelBuffer` into an `MTLTexture` via a `CVMetalTextureCache` — **zero-copy** when the buffer is IOSurface-backed (which is why §3.6 sets `kCVPixelBufferIOSurfacePropertiesKey`). It branches on pixel format:

- **BGRA** (the libav path, and 8-bit AVFoundation fallback): one RGBA texture, sample as RGB.
- **Biplanar 10-bit YCbCr** (`kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange`, the ProRes/10-bit-DNx native path): **two** textures — a luma plane and a chroma plane — converted to RGB in the shader. You must **retain the `CVMetalTexture` objects** (not just the `MTLTexture`) for as long as you render them; releasing the CV texture invalidates the Metal texture.

```swift
let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
// → choose BGRA path or biplanar path; create CVMetalTexture(s) from the cache;
//   keep strong refs to the CVMetalTexture(s); hand MTLTexture(s) to the shader.
var cvTexture: CVMetalTexture?
CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer,
                                          nil, .bgra8Unorm, width, height, 0, &cvTexture)
let mtlTexture = cvTexture.map(CVMetalTextureGetTexture)   // retain cvTexture!
```

If you only ever take the libav BGRA path, you can drop the biplanar branch entirely and your shader is trivial (sample, optional color work, present). The biplanar branch only earns its keep if you also play ProRes natively.

---

## 9. Timecode sync — the part you actually care about

You want to scrub a **Pro Tools session** and have the video follow. The mapping you need, per video clip:

```
sessionFrame      = sessionTimecode_in_frames          // your transport's current position
clipStartFrame    = decoder.startTimecodeFrames        // embedded source start TC (frames from midnight)
sourceFrameIndex  = sessionFrame - clipStartFrame       // 0-based index into the decoder

if sourceFrameIndex in 0..<decoder.totalFrames {
    pixelBuffer = cache.cachedFrame(at: sourceFrameIndex)   // show it
} else {
    // session playhead is outside this clip's media — show black / adjacent clip
}
```

Everything is already in the same unit (**frames from midnight**) because both decoders normalize TC that way. Concretely:

- Pro Tools spots clips on the timeline at session timecodes. If your browser knows a clip's session-timeline TC and the **same clip's source start TC** (`startTimecodeFrames`), the offset is constant and the formula above is exact.
- For a single "follow the playhead" preview where the video *is* the reference (e.g., previewing one master clip against the session), `sourceFrameIndex = sessionFrame - clipStartFrame` directly.

**Drop-frame caveat (read this):** Walter's `parseTimecodeToFrames` does **not** apply drop-frame compensation, because it only needs relative offsets within a single rate. Pro Tools sessions are frequently **29.97 DF**. If your session TC and your clip TC can be different drop/non-drop conventions, you must convert both to a true frame count with proper DF math before subtracting, or your sync will drift by ~3.6 s/hour. Minimal DF→frames:

```swift
// 29.97 drop-frame: drop frames 0 and 1 at the start of every minute except every 10th minute.
func dropFrameToFrames(h: Int, m: Int, s: Int, f: Int) -> Int {
    let totalMinutes = 60 * h + m
    let frameNumber = 30 * (3600 * h + 60 * m + s) + f - 2 * (totalMinutes - totalMinutes / 10)
    return frameNumber
}
```

(Use the analogous formula for 59.94. Keep non-drop on the simple path.)

---

## 10. Audio — in-process MXF audio + the OP-Atom companion model

This matters for you specifically. Two facts about **Avid OP-Atom MXF**:

1. **Video and audio are separate files.** The picture lives in `…_V1.mxf` (no audio stream); each audio channel lives in a companion `…_A1.mxf`, `…_A2.mxf`, etc. To get audio for a clip you resolve and open the companion.
2. **Decode it in-process too** — same FFmpeg libs, via `libswresample`. No subprocess, no temp files.

`LibavAudioExtractor` decodes the first audio stream and **resamples to mono float32** at a target rate (Walter uses 24 kHz — Nyquist at 12 kHz is plenty for monitoring and halves memory; you'll likely want 48 kHz to match Pro Tools), returning an `AVAudioPCMBuffer`:

```swift
enum LibavAudioExtractor {
    /// Decode + resample url's first audio stream → mono float32 AVAudioPCMBuffer.
    /// All libav work is synchronous; the async signature just lets callers await
    /// without parking a thread on a semaphore.
    static func extract(url: URL, sampleRate: Double = 48000.0) async -> AVAudioPCMBuffer? {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&fmtCtx, url.path, nil, nil) == 0, fmtCtx != nil else { return nil }
        defer { avformat_close_input(&fmtCtx) }
        guard avformat_find_stream_info(fmtCtx, nil) >= 0 else { return nil }

        // first audio stream → find decoder → alloc/param/open codec context
        // → av_read_frame / avcodec_send_packet / avcodec_receive_frame loop
        // → swr_convert each frame into an AVAudioPCMBuffer (.pcmFormatFloat32, 1 ch, non-interleaved)
        // (mirror the video pump in §3.3, but feed libswresample instead of libswscale)
    }
}
```

The extractor is **source-agnostic** — hand it a standalone `_A1.mxf`, a self-contained `.mov`, or a WAV and it demuxes whatever audio it finds. Your scanner resolves which file carries the audio and passes that URL.

### Audio playback + pitch-coupled scrub

Walter plays audio through an `AVAudioSourceNode` render callback (no time-stretching — pitch follows transport speed, like a real flatbed). It shares one decoded-buffer pool across both decks so audio memory never doubles, with an LRU cap and **lazy windowed extraction**: audio for a segment is only decoded when the playhead gets near it (±N segments), not eagerly on load. For a session browser that scans large sessions, **lazy extraction around the playhead is the pattern to copy** — don't decode every clip's audio up front.

For a timecode-synced *preview* (as opposed to playback), you may not even need Walter's pitch-coupled engine — standard `AVAudioPlayerNode` scheduling against the same TC→frame mapping is fine. The reusable pieces are: (a) in-process MXF audio decode, (b) the OP-Atom companion-file resolution, (c) lazy windowed extraction, (d) shared buffer pool + LRU cap.

---

## 11. Concurrency / thread-safety notes (don't skip)

- **A libav codec context is not thread-safe.** One `NSLock` per `LibavDecoder`; serialize every `decodeSample`. For parallel prefetch, build **multiple decoder instances** against the same URL — don't share one across threads.
- Mark decoders/caches `@unchecked Sendable` and funnel all shared-state mutation through their lock. This is honest about pre-existing cross-thread use (display-link reads, background prefetch, main-thread teardown).
- **Never hold your cache-manager lock across a decode call.** Snapshot the relevant per-source cache under the lock, release, then call into it.
- **Don't lock the realtime audio render callback.** Give it a lock-free snapshot of the buffer it needs; locking a CoreAudio render thread risks glitches.
- macOS 26-era Swift marks `NSLock.lock()/unlock()` `@noasync`. If you call them from `async` functions, wrap them in trivial sync `acquire()/release()` proxies — the `@noasync` check fires at the immediate call site and doesn't propagate through a sync wrapper. (You own the contract: no `await` between acquire and release on the same lock.)

---

## 12. Licensing — the catch with FFmpeg

FFmpeg is **LGPL** (GPL if you enable certain components). For DNxHD/DNxHR + MXF + PCM/AAC audio you stay within LGPL-licensed code, but you must honor LGPL: ship the license text, and link **dynamically** (or otherwise allow the user to relink) rather than statically baking it in. Homebrew's `ffmpeg` is a dynamic build. If you bundle the dylibs in your `.app`, include the FFmpeg `NOTICE`/`COPYING` files and keep them as separate, replaceable dylibs. Get this reviewed before you ship commercially — it's the one non-technical landmine in this whole approach.

---

## 13. Quick-start checklist for your assistant

1. `brew install ffmpeg`; add the `CFFmpeg` system-library target (§2). Confirm `import CFFmpeg` compiles.
2. Port `LibavDecoder` (§3). Test: open a DNxHD MXF, decode frame 0, decode frame 1000, seek back to frame 10. Verify time-to-first-frame is tens of **milliseconds**, not seconds.
3. Wrap it in a dictionary-backed cache with inline-decode-on-miss + nearest-frame fallback (§6).
4. Render the BGRA `CVPixelBuffer` via `CVMetalTextureCache` (§8). If you don't need native ProRes, skip the biplanar branch.
5. Wire TC→frame mapping (§9). **Decide your drop-frame policy up front.**
6. Add in-process MXF audio via `libswresample` + OP-Atom companion resolution (§10), lazily around the playhead.
7. Only add the AVFoundation/`ProResDecoder` path (§4) if you also need ProRes/H.264 — DNx never needs it.
8. Sort out FFmpeg/LGPL licensing before release (§12).

---

## 14. Source-file map (Walter tree, for reference)

```
Sources/CFFmpeg/
  module.modulemap, shim.h          # Swift→FFmpeg bridge (§2)
Sources/Walter/Video/
  LibavDecoder.swift                # in-process DNx/MXF decode (§3)  ← the core of the handoff
  LibavFrameCache.swift             # minimal cache + rolling prefetch (§6)
  ProResDecoder.swift               # AVFoundation decode + native pixel formats (§4)
  FrameCache.swift                  # full prefetch-pool cache for ProRes/H.264
  FrameCacheManager.swift           # codec-based routing + unified metadata (§5)
  MXF/                              # in-house OP-Atom MXF parser (KLV/index/essence) — optional;
                                    #   libavformat already demuxes MXF, this is for deep metadata
Sources/Walter/Audio/
  LibavAudioExtractor.swift         # in-process MXF audio via libswresample (§10)
  AudioBufferPool.swift             # shared decoded-audio pool, lazy window, LRU cap
  AudioTransport.swift              # AVAudioSourceNode pitch-coupled playback
Sources/Walter/Rendering/
  FilmGateRenderer.swift            # CVPixelBuffer → MTLTexture (BGRA + biplanar) (§8)
  ViewerView.swift                  # pull-based MTKView, reads currentFrame each vsync (§7)
```

---

### Measured numbers (M1 Max, 2K DNxHD MXF), so your assistant has targets
- Cold-start time-to-first-frame: **~33 ms** (libav) vs. **~40,000 ms** (AVFoundation/VT/XPC).
- Steady-state decode: **~1.6 ms/frame** (~26× real-time at 24 fps).
- Per-frame budget at 24 fps: **~41 ms** → ~25× headroom, which is why the DNx cache needs no decoder pool.

If your assistant has questions about a specific function, the function names above are exact — point it at the matching file.
