import CoreMedia
import CoreVideo
import Foundation
import CFFmpeg

/// In-process video decoder built on libavformat/libavcodec/libswscale (FFmpeg).
/// Decodes DNxHD/DNxHR/ProRes/H.264/HEVC/… to BGRA `CVPixelBuffer`s with frame-accurate
/// seeking. Bypasses VideoToolbox entirely — no XPC cold-start tax on DNx.
///
/// Main-app only (imports CFFmpeg). A libavcodec context is NOT thread-safe, so every
/// decode path is serialized by `lock`; for parallel prefetch, build multiple decoders.
/// Authority for this port: the "Walter" engineering handoff, §3.
final class LibavDecoder: @unchecked Sendable {
    let sourceURL: URL
    let totalFrames: Int
    let fps: Double
    let dimensions: CGSize
    let duration: CMTime
    let startTimecodeFrames: Int?   // frames from midnight, nil if no embedded TC
    let reelName: String

    private let lock = NSLock()
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private let videoStreamIndex: Int32
    private let streamTimeBase: AVRational
    private let frameRate: AVRational
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var swsCtx: UnsafeMutablePointer<SwsContext>?
    private var swsCachedSrcFormat: Int32 = -1
    private var swsCachedSize: (Int, Int) = (0, 0)
    private var currentFrameIndex: Int = -1   // -1 = nothing decoded / post-flush

    // AVERROR(EAGAIN) / AVERROR_EOF are C macros — invisible to Swift. Redeclare.
    private static let AVERROR_EAGAIN: Int32 = -35            // -EAGAIN (EAGAIN == 35 on macOS)
    private static let AVERROR_EOF:    Int32 = -541478725     // FFERRTAG('E','O','F',' ')

    private init(sourceURL: URL, totalFrames: Int, fps: Double, dimensions: CGSize,
                 duration: CMTime, startTimecodeFrames: Int?, reelName: String,
                 formatCtx: UnsafeMutablePointer<AVFormatContext>?,
                 codecCtx: UnsafeMutablePointer<AVCodecContext>?,
                 videoStreamIndex: Int32, streamTimeBase: AVRational, frameRate: AVRational,
                 packet: UnsafeMutablePointer<AVPacket>?, frame: UnsafeMutablePointer<AVFrame>?) {
        self.sourceURL = sourceURL
        self.totalFrames = totalFrames
        self.fps = fps
        self.dimensions = dimensions
        self.duration = duration
        self.startTimecodeFrames = startTimecodeFrames
        self.reelName = reelName
        self.formatCtx = formatCtx
        self.codecCtx = codecCtx
        self.videoStreamIndex = videoStreamIndex
        self.streamTimeBase = streamTimeBase
        self.frameRate = frameRate
        self.packet = packet
        self.frame = frame
    }

    // MARK: Open

    static func make(url: URL) async -> LibavDecoder? {
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&formatCtx, url.path, nil, nil) == 0, formatCtx != nil else {
            return nil
        }
        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            avformat_close_input(&formatCtx); return nil
        }

        // First video stream.
        let nStreams = Int(formatCtx!.pointee.nb_streams)
        var videoStreamIdx: Int32 = -1
        for i in 0..<nStreams {
            guard let stream = formatCtx!.pointee.streams[i] else { continue }
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIdx = Int32(i); break
            }
        }
        guard videoStreamIdx >= 0, let videoStream = formatCtx!.pointee.streams[Int(videoStreamIdx)] else {
            avformat_close_input(&formatCtx); return nil
        }
        let codecpar = videoStream.pointee.codecpar!

        // Find + open decoder.
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id),
              var codecCtx = avcodec_alloc_context3(codec) else {
            avformat_close_input(&formatCtx); return nil
        }
        var codecCtxOpt: UnsafeMutablePointer<AVCodecContext>? = codecCtx
        guard avcodec_parameters_to_context(codecCtxOpt, codecpar) >= 0 else {
            avcodec_free_context(&codecCtxOpt); avformat_close_input(&formatCtx); return nil
        }
        // Single-threaded decode: frame/slice threading is seek-hostile (decoder delay +
        // out-of-order priming after flush) and can saturate every core during prefetch.
        // Single-threaded DNxHD/ProRes decode is still well above real-time for a preview deck.
        codecCtx.pointee.thread_count = 1
        codecCtx.pointee.thread_type = 0
        guard avcodec_open2(codecCtxOpt, codec, nil) == 0 else {
            avcodec_free_context(&codecCtxOpt); avformat_close_input(&formatCtx); return nil
        }

        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else {
            avcodec_free_context(&codecCtxOpt); avformat_close_input(&formatCtx); return nil
        }

        // fps / frame count / duration.
        let timeBase = videoStream.pointee.time_base
        let avgFR = videoStream.pointee.avg_frame_rate
        let rFR   = videoStream.pointee.r_frame_rate
        let frameRate: AVRational =
            (avgFR.num > 0 && avgFR.den > 0) ? avgFR :
            (rFR.num   > 0 && rFR.den   > 0) ? rFR   : AVRational(num: 24, den: 1)
        let fps = Double(frameRate.num) / Double(frameRate.den)

        let streamFrames = videoStream.pointee.nb_frames
        let durationSec: Double =
            formatCtx!.pointee.duration > 0 ? Double(formatCtx!.pointee.duration) / Double(AV_TIME_BASE) :
            videoStream.pointee.duration > 0 ? Double(videoStream.pointee.duration) * Double(timeBase.num) / Double(timeBase.den) : 0
        let totalFrames: Int =
            streamFrames > 0 ? Int(streamFrames) :
            durationSec  > 0 ? Int((durationSec * fps).rounded()) : 0

        let dims = CGSize(width: Int(codecpar.pointee.width), height: Int(codecpar.pointee.height))
        let durationCM = CMTime(seconds: durationSec, preferredTimescale: 600)

        // Metadata: reel name + start timecode.
        func dictGet(_ dict: OpaquePointer?, _ key: String) -> String? {
            guard let dict, let e = av_dict_get(dict, key, nil, 0), let v = e.pointee.value else { return nil }
            return String(cString: v)
        }
        let formatMeta = formatCtx!.pointee.metadata
        let streamMeta = videoStream.pointee.metadata
        let reelName = dictGet(streamMeta, "reel_name")
            ?? dictGet(formatMeta, "material_package_name")
            ?? url.deletingPathExtension().lastPathComponent
        let tcString = dictGet(streamMeta, "timecode") ?? dictGet(formatMeta, "timecode")
        let startTC = tcString.flatMap { parseTimecodeToFrames($0, fps: fps) }

        return LibavDecoder(
            sourceURL: url, totalFrames: totalFrames, fps: fps, dimensions: dims,
            duration: durationCM, startTimecodeFrames: startTC, reelName: reelName,
            formatCtx: formatCtx, codecCtx: codecCtxOpt, videoStreamIndex: videoStreamIdx,
            streamTimeBase: timeBase, frameRate: frameRate, packet: packet, frame: frame)
    }

    /// "HH:MM:SS:FF" or drop-frame "HH:MM:SS;FF" → frames from midnight (no DF compensation).
    private static func parseTimecodeToFrames(_ tc: String, fps: Double) -> Int? {
        let parts = tc.replacingOccurrences(of: ";", with: ":").split(separator: ":").map(String.init)
        guard parts.count == 4, let h = Int(parts[0]), let m = Int(parts[1]),
              let s = Int(parts[2]), let f = Int(parts[3]) else { return nil }
        let fpsInt = Int(fps.rounded())
        return ((h * 3600 + m * 60 + s) * fpsInt) + f
    }

    // MARK: Decode

    /// Decode one frame by index → BGRA `CMSampleBuffer`. DNx is all-intra so a seek lands
    /// exactly; long-GOP codecs seek to the prior keyframe and decode forward.
    func decodeSample(at index: Int) -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < totalFrames,
              formatCtx != nil, codecCtx != nil, packet != nil, frame != nil else { return nil }

        if currentFrameIndex < 0 || index < currentFrameIndex || index > currentFrameIndex + 60 {
            seekLocked(to: index)
        }
        var safety = 0
        while currentFrameIndex < index {
            guard decodeOneFrameLocked() else { return nil }
            safety += 1
            if safety > totalFrames + 100 { return nil }
        }
        return makeSampleBufferLocked(frameIndex: index)
    }

    private func seekLocked(to index: Int) {
        guard let formatCtx, let codecCtx else { return }
        av_seek_frame(formatCtx, videoStreamIndex, ptsForFrame(index), AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)
        currentFrameIndex = index - 1   // decode loop advances one at a time to land on index
    }

    private func ptsForFrame(_ index: Int) -> Int64 {
        // frame_duration (timebase units) = (frameRate.den / frameRate.num) / streamTimeBase
        av_rescale_q(Int64(index),
                     AVRational(num: frameRate.den, den: frameRate.num),
                     streamTimeBase)
    }

    private func decodeOneFrameLocked() -> Bool {
        guard let formatCtx, let codecCtx, let packet, let frame else { return false }
        while true {
            let recv = avcodec_receive_frame(codecCtx, frame)
            if recv == 0 { currentFrameIndex += 1; return true }
            if recv != Self.AVERROR_EAGAIN { return false }   // EOF or hard error

            let read = av_read_frame(formatCtx, packet)
            if read < 0 {                                      // EOF → flush decoder, drain
                avcodec_send_packet(codecCtx, nil); continue
            }
            defer { av_packet_unref(packet) }
            if packet.pointee.stream_index != videoStreamIndex { continue }
            let send = avcodec_send_packet(codecCtx, packet)
            if send < 0 && send != Self.AVERROR_EAGAIN { return false }
        }
    }

    private func makeSampleBufferLocked(frameIndex: Int) -> CMSampleBuffer? {
        guard let frame else { return nil }
        let srcW = Int(frame.pointee.width), srcH = Int(frame.pointee.height)
        let srcFormat = frame.pointee.format
        guard srcW > 0, srcH > 0 else { return nil }

        if swsCtx == nil || swsCachedSrcFormat != srcFormat || swsCachedSize != (srcW, srcH) {
            if let existing = swsCtx { sws_freeContext(existing) }
            swsCtx = sws_getContext(Int32(srcW), Int32(srcH), AVPixelFormat(rawValue: srcFormat),
                                    Int32(srcW), Int32(srcH), AV_PIX_FMT_BGRA,
                                    Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            swsCachedSrcFormat = srcFormat; swsCachedSize = (srcW, srcH)
            guard swsCtx != nil else { return nil }
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dstBase = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(pb)

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
        var dstSlices: [UnsafeMutablePointer<UInt8>?] =
            [dstBase.assumingMemoryBound(to: UInt8.self), nil, nil, nil, nil, nil, nil, nil]
        var dstStrides: [Int32] = [Int32(dstStride), 0, 0, 0, 0, 0, 0, 0]

        _ = sws_scale(swsCtx, &srcSlices, &srcStrides, 0, Int32(srcH), &dstSlices, &dstStrides)

        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pb, formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return nil }
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

    deinit {
        if let swsCtx { sws_freeContext(swsCtx) }
        if packet   != nil { av_packet_free(&packet) }
        if frame    != nil { av_frame_free(&frame) }
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        if formatCtx != nil { avformat_close_input(&formatCtx) }
    }
}
