import AVFoundation
import CoreAudio
import Combine

// MARK: - Audio device enumeration

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

enum AudioDeviceManager {

    static func outputDevices() -> [AudioOutputDevice] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids   = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &ids) == noErr
        else { return [] }

        return ids.compactMap { outputDevice(id: $0) }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        outputDevices().first { $0.uid == uid }?.id
    }

    /// Routes an AVAudioEngine's output to the given CoreAudio device.
    /// Must be called while the engine is stopped.
    static func setEngineOutputDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID) {
        guard let audioUnit = engine.outputNode.audioUnit else { return }
        var id   = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0, &id, size)
    }

    // MARK: Private helpers

    private static func outputDevice(id: AudioDeviceID) -> AudioOutputDevice? {
        // Require at least one output stream
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope:    kAudioObjectPropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize)
        guard streamsSize > 0 else { return nil }

        let name = cfStringProperty(id: id, selector: kAudioObjectPropertyName)
        let uid  = cfStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID)
        guard !name.isEmpty, !uid.isEmpty else { return nil }
        return AudioOutputDevice(id: id, name: name, uid: uid)
    }

    private static func cfStringProperty(id: AudioObjectID,
                                         selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let raw = ref else { return "" }
        return raw.takeRetainedValue() as String
    }
}

// MARK: - AudioPlayer

final class AudioPlayer: ObservableObject, @unchecked Sendable {
    @Published var isPlaying:       Bool      = false
    @Published var playingClip:     PTXClip?  = nil
    @Published var isPlayingRegion: Bool      = false   // true when playRegion() is active
    @Published var playbackFraction: Double   = 0       // 0…1 within the clip's duration
    @Published var volume: Float = 1.0 {                // linear gain; 1.0 = unity, >1.0 = over-unity
        didSet { gainNode.volume = volume }
    }

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let gainNode   = AVAudioMixerNode()
    private var stopWorkItem: DispatchWorkItem?
    private var ticker:       Timer?
    private var clipDurSec:   Double = 1   // remaining scheduled duration (for stop timer)
    private var fullDurSec:   Double = 1   // full clip duration (for playbackFraction math)
    private var seekFraction: Double = 0   // 0..1 within clip where playback started

    // Extra player nodes created for multi-track region playback.
    // Cleaned up in stop() so the engine doesn't accumulate nodes.
    private var regionNodes: [AVAudioPlayerNode] = []
    // Incremented by stop() / play() so background tasks can detect cancellation.
    private var regionGeneration: Int = 0
    private var clipGeneration:   UInt64 = 0
    private var clipPlayStart:    Date?          // wall-clock time playback began (for playhead)

    init() {
        engine.attach(playerNode)
        engine.attach(gainNode)
        engine.connect(playerNode, to: gainNode, format: nil)
        engine.connect(gainNode, to: engine.mainMixerNode, format: nil)
    }

    // MARK: Device routing

    /// Switch the output device. Stops any current playback; engine restarts on next play().
    func setOutputDevice(uid: String) {
        if isPlaying { stop() }
        if engine.isRunning { engine.stop() }
        if let deviceID = AudioDeviceManager.deviceID(forUID: uid) {
            AudioDeviceManager.setEngineOutputDevice(engine, deviceID: deviceID)
        }
        // Engine restarts lazily in play()
    }

    // MARK: Playback

    /// Parse a Pro Tools multi-mono channel suffix (".AN") from a clip name.
    /// Returns the 0-based channel index, or nil if not a multi-mono clip.
    /// e.g. "myFile.A3" → 2  (channel 3, 0-based = 2)
    static func channelIndex(fromClipName name: String) -> Int? {
        guard let range = name.range(of: #"\.A(\d+)$"#, options: .regularExpression) else { return nil }
        let suffix = name[range]           // e.g. ".A3"
        guard let n = Int(suffix.dropFirst(2)), n >= 1 else { return nil }
        return n - 1                       // 1-indexed → 0-based
    }

    /// Start (or restart) playback from `fromFraction` (0…1) within the clip.
    /// - Parameter channelIndex: When non-nil, extracts that 0-based channel from an
    ///   interleaved file and plays it as mono.  Overrides any channel index encoded in
    ///   the clip name (`.AN` suffix convention).  Pass nil to play all channels.
    func play(clip: PTXClip, url: URL, sampleRate: Double, fromFraction: Double = 0,
              channelIndex: Int? = nil) {
        stop()

        // Apply the currently-stored device preference before starting
        let prefUID = UserDefaults.standard.string(forKey: "audioOutputDeviceUID") ?? ""
        if !prefUID.isEmpty, let deviceID = AudioDeviceManager.deviceID(forUID: prefUID) {
            if engine.isRunning { engine.stop() }
            AudioDeviceManager.setEngineOutputDevice(engine, deviceID: deviceID)
        }

        guard let file = try? AVAudioFile(forReading: url) else { return }

        let clampedFrac = max(0, min(0.9999, fromFraction))
        seekFraction  = clampedFrac
        fullDurSec    = max(Double(clip.lengthSamples) / max(sampleRate, 1), 0.001)

        let seekSamples      = Int64(clampedFrac * Double(clip.lengthSamples))
        let remainingSamples = max(clip.lengthSamples - seekSamples, 0)
        clipDurSec           = max(Double(remainingSamples) / max(sampleRate, 1), 0.001)

        let startFrame = AVAudioFramePosition(clip.sourceOffset + seekSamples)

        let chIdx  = channelIndex ?? AudioPlayer.channelIndex(fromClipName: clip.name)
        let fileCh = Int(file.processingFormat.channelCount)
        let fileSR = file.processingFormat.sampleRate

        // Reconnect playerNode so format always matches the buffer being scheduled.
        let outCh  = (chIdx != nil || fileCh > 2) ? 1 : fileCh
        guard let outFmt = AVAudioFormat(standardFormatWithSampleRate: fileSR,
                                         channels: AVAudioChannelCount(outCh)) else { return }
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: gainNode, format: outFmt)
        if !engine.isRunning { try? engine.start() }

        // Channel-remap helper: read srcBuf into outBuf applying chIdx / multichannel mix.
        let procFmt = file.processingFormat
        func remapInto(_ src: AVAudioPCMBuffer, _ out: AVAudioPCMBuffer) -> Bool {
            guard let sd = src.floatChannelData, let dd = out.floatChannelData else { return false }
            out.frameLength = src.frameLength
            let n = Int(src.frameLength)
            if let ch = chIdx, ch < fileCh {
                memcpy(dd[0], sd[ch], n * MemoryLayout<Float>.size)
            } else if fileCh > 2 {
                let scale = Float(1.0 / Double(fileCh))
                for f in 0..<n { var s: Float = 0; for c in 0..<fileCh { s += sd[c][f] }; dd[0][f] = s * scale }
            } else {
                for c in 0..<outCh { memcpy(dd[c], sd[c], n * MemoryLayout<Float>.size) }
            }
            return true
        }

        // ── First chunk: read synchronously → play starts immediately ────────
        // Keep the first chunk short (0.25 s) so the main thread isn't blocked
        // reading a large multichannel file.  The streaming loop immediately
        // pre-fills more buffers so there's no risk of underrun.
        let kChunkFrames  = Int64(fileSR * 5.0)   // streaming chunks: 5 s
        let kFirstFrames  = Int64(fileSR * 0.25)  // first sync chunk: 0.25 s
        let firstCount   = AVAudioFrameCount(min(Int64(remainingSamples), kFirstFrames))
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: procFmt, frameCapacity: firstCount),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt,  frameCapacity: firstCount)
        else { return }
        file.framePosition = startFrame
        guard (try? file.read(into: srcBuf, frameCount: firstCount)) != nil,
              srcBuf.frameLength > 0, remapInto(srcBuf, outBuf) else { return }

        playerNode.scheduleBuffer(outBuf, at: nil)
        playerNode.play()

        isPlaying        = true
        playingClip      = clip
        playbackFraction = clampedFrac
        clipPlayStart    = Date()

        // Timer to stop at clip end
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + clipDurSec, execute: work)

        // ~60 fps ticker for playhead — wall-clock based, scheduled on .common
        // so it keeps firing during scroll/drag interactions (.default gets starved).
        // Subtract presentationLatency so the playhead matches what the ears hear,
        // not what the engine has merely rendered into the hardware buffer.
        let outputLatency = engine.outputNode.presentationLatency
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, let startDate = self.clipPlayStart else { return }
            let elapsed = max(0, Date().timeIntervalSince(startDate) - outputLatency)
            self.playbackFraction = max(0, min(1, self.seekFraction + elapsed / self.fullDurSec))
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        // ── Stream remaining chunks in background ─────────────────────────────
        let framesScheduled = Int64(firstCount)
        guard framesScheduled < remainingSamples else { return }

        clipGeneration &+= 1
        let myGen      = clipGeneration
        let nextStart  = startFrame + framesScheduled
        let framesLeft = remainingSamples - framesScheduled

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let streamFile = try? AVAudioFile(forReading: url) else { return }
            streamFile.framePosition = nextStart
            var offset: Int64 = 0
            while offset < framesLeft {
                guard self.clipGeneration == myGen else { return }
                let count = AVAudioFrameCount(min(kChunkFrames, framesLeft - offset))
                guard let src = AVAudioPCMBuffer(pcmFormat: procFmt, frameCapacity: count),
                      let out = AVAudioPCMBuffer(pcmFormat: outFmt,  frameCapacity: count),
                      (try? streamFile.read(into: src, frameCount: count)) != nil,
                      src.frameLength > 0
                else { break }
                guard let sd = src.floatChannelData, let dd = out.floatChannelData else { break }
                out.frameLength = src.frameLength
                let n = Int(src.frameLength)
                if let ch = chIdx, ch < fileCh {
                    memcpy(dd[0], sd[ch], n * MemoryLayout<Float>.size)
                } else if fileCh > 2 {
                    let scale = Float(1.0 / Double(fileCh))
                    for f in 0..<n { var s: Float = 0; for c in 0..<fileCh { s += sd[c][f] }; dd[0][f] = s * scale }
                } else {
                    for c in 0..<outCh { memcpy(dd[c], sd[c], n * MemoryLayout<Float>.size) }
                }
                guard self.clipGeneration == myGen else { return }
                self.playerNode.scheduleBuffer(out, at: nil)
                offset += Int64(count)
            }
        }
    }

    func stop() {
        regionGeneration &+= 1   // cancel any in-flight async region build
        clipGeneration   &+= 1   // cancel any in-flight clip streaming task
        stopWorkItem?.cancel()
        stopWorkItem = nil
        ticker?.invalidate()
        ticker           = nil
        playerNode.stop()
        // Tear down any extra nodes created by playRegion()
        for node in regionNodes {
            node.stop()
            engine.detach(node)
        }
        regionNodes      = []
        isPlaying        = false
        isPlayingRegion  = false
        playingClip      = nil
        playbackFraction = 0
        clipPlayStart    = nil
    }

    // MARK: - Region playback

    /// Plays a multi-clip region: one stitched buffer per track, all started simultaneously.
    /// Clips within each track are separated by silence to preserve their timeline spacing.
    /// Safe to call from any thread; all AVAudioEngine work is dispatched to the main queue.
    func playRegion(_ region: PlayRegion) {
        stop()   // increments regionGeneration

        guard !region.segments.isEmpty else { return }

        // Apply stored output device preference
        let prefUID = UserDefaults.standard.string(forKey: "audioOutputDeviceUID") ?? ""
        if !prefUID.isEmpty, let deviceID = AudioDeviceManager.deviceID(forUID: prefUID) {
            if engine.isRunning { engine.stop() }
            AudioDeviceManager.setEngineOutputDevice(engine, deviceID: deviceID)
        }

        let sr = region.sampleRate > 0 ? region.sampleRate : 48000
        guard let monoFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }
        let regionFrames = AVAudioFrameCount(region.endSample - region.startSample)
        guard regionFrames > 0 else { return }

        // Capture generation so the background build can verify it's still wanted.
        let generation = regionGeneration

        // Build all PCM buffers on a background thread — file I/O can be slow
        // for large selections and must not block the main/UI thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var readyBuffers: [AVAudioPCMBuffer] = []

            for segment in region.segments {
                guard let stitched = AVAudioPCMBuffer(pcmFormat: monoFmt,
                                                      frameCapacity: regionFrames) else { continue }
                stitched.frameLength = regionFrames
                if let ptr = stitched.floatChannelData?[0] {
                    ptr.initialize(repeating: 0, count: Int(regionFrames))
                }

                var wroteAny = false
                for (clip, url) in segment.clips {
                    guard let file = try? AVAudioFile(forReading: url) else { continue }

                    let clipStart  = max(clip.startSample, region.startSample)
                    let clipEnd    = min(clip.startSample + clip.lengthSamples, region.endSample)
                    guard clipEnd > clipStart else { continue }

                    let clipFrames = AVAudioFrameCount(clipEnd - clipStart)
                    let bufOffset  = Int(clipStart - region.startSample)
                    let fileStart  = AVAudioFramePosition(clip.sourceOffset + (clipStart - clip.startSample))

                    guard let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                         frameCapacity: clipFrames) else { continue }
                    file.framePosition = fileStart
                    guard (try? file.read(into: srcBuf, frameCount: clipFrames)) != nil,
                          srcBuf.frameLength > 0,
                          let channelData = srcBuf.floatChannelData else { continue }

                    let chIdx  = AudioPlayer.channelIndex(fromClipName: clip.name)
                    let fileCh = Int(srcBuf.format.channelCount)

                    if let dst = stitched.floatChannelData?[0] {
                        guard bufOffset < Int(regionFrames) else { continue }
                        let available = Int(regionFrames) - bufOffset
                        let count = min(Int(srcBuf.frameLength), available)
                        guard count > 0 else { continue }
                        if let ch = chIdx {
                            // Multi-mono: extract the specific channel
                            let srcCh = min(ch, fileCh - 1)
                            memcpy(dst + bufOffset, channelData[srcCh], count * MemoryLayout<Float>.size)
                        } else if fileCh > 1 {
                            // Interleaved multichannel: equal-weight mix to mono
                            let scale = Float(1.0 / Double(fileCh))
                            for f in 0..<count {
                                var sum: Float = 0
                                for c in 0..<fileCh { sum += channelData[c][f] }
                                (dst + bufOffset)[f] = sum * scale
                            }
                        } else {
                            memcpy(dst + bufOffset, channelData[0], count * MemoryLayout<Float>.size)
                        }
                        wroteAny = true
                    }
                }
                if wroteAny { readyBuffers.append(stitched) }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.regionGeneration == generation else { return }
                guard !readyBuffers.isEmpty else { return }

                var readyNodes: [AVAudioPlayerNode] = []
                for buf in readyBuffers {
                    let node = AVAudioPlayerNode()
                    self.engine.attach(node)
                    self.engine.connect(node, to: self.gainNode, format: monoFmt)
                    node.scheduleBuffer(buf, at: nil)
                    readyNodes.append(node)
                }

                if !self.engine.isRunning { try? self.engine.start() }

                let startTime = AVAudioTime(hostTime: mach_absolute_time() + self.msToHostTicks(20))
                for node in readyNodes { node.play(at: startTime) }

                self.regionNodes     = readyNodes
                self.isPlaying       = true
                self.isPlayingRegion = true

                let durSec = Double(regionFrames) / sr
                let work = DispatchWorkItem { [weak self] in self?.stop() }
                self.stopWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + durSec, execute: work)

                let startDate = Date()
                self.ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.playbackFraction = max(0, min(1, Date().timeIntervalSince(startDate) / durSec))
                }
            }
        }
    }

    // Convert milliseconds to Mach absolute time ticks (used for AVAudioTime sync).
    private func msToHostTicks(_ ms: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = ms * 1_000_000
        return UInt64(nanos * Double(info.denom) / Double(info.numer))
    }

    // MARK: - Waveform loading

    /// Reads PCM peaks for the clip region, one `[Float]` per channel (normalised 0…1).
    /// Uses AVAudioFile whose `processingFormat` is always float32 deinterleaved —
    /// giving reliable per-channel data without AVAssetReader channel-count ambiguity.
    /// Pass `channelIndex` (0-based) to return only that channel (e.g. for multichannel files).
    static func loadWaveform(url: URL, startSample: Int64, lengthSamples: Int64,
                             resolution: Int = 500,
                             channelIndex: Int? = nil, normalized: Bool = true,
                             sparse: Bool = false) async -> [[Float]] {
        // Cache hit?
        if let cached = WaveformCache.shared.get(audioURL: url, startSample: startSample,
                                                  lengthSamples: lengthSamples, resolution: resolution,
                                                  channelIndex: channelIndex, normalized: normalized,
                                                  sparse: sparse) {
            return cached
        }

        guard let file = try? AVAudioFile(forReading: url) else { return [] }

        // processingFormat is guaranteed float32 non-interleaved with the correct channel count.
        let fmt = file.processingFormat
        let ch  = Int(fmt.channelCount)

        let totalFrames  = Int(lengthSamples)
        let bucketFrames = max(1, totalFrames / resolution)

        var peaks = [[Float]](repeating: [Float](repeating: 0, count: resolution), count: ch)

        // Sparse mode: only worthwhile when buckets are large enough that seeking saves
        // significant I/O. For short clips (small bucketFrames) the contiguous path is
        // faster because AVAudioFile prefetches on each seek, wasting more than it saves.
        if sparse && bucketFrames > 4096 {
            // Read up to 4096 frames at the start of each bucket, then seek to the next.
            // 4096 frames ≈ one OS page worth of audio, keeping seeks page-aligned and
            // reducing thrash on the disk cache used by concurrent playback reads.
            let readPerBucket = AVAudioFrameCount(min(bucketFrames, 4096))
            guard let smallBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: readPerBucket) else { return [] }
            for bucket in 0..<resolution {
                file.framePosition = startSample + Int64(bucket * bucketFrames)
                smallBuf.frameLength = 0
                do { try file.read(into: smallBuf, frameCount: readPerBucket) } catch { break }
                guard let channelData = smallBuf.floatChannelData else { continue }
                let n = Int(smallBuf.frameLength)
                for f in 0..<n {
                    for c in 0..<ch {
                        peaks[c][bucket] = max(peaks[c][bucket], abs(channelData[c][f]))
                    }
                }
            }
        } else {
            let chunkSize = AVAudioFrameCount(min(totalFrames, 65536))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkSize) else { return [] }
            file.framePosition = startSample   // seek to clip start
            var frameIdx = 0
            while frameIdx < totalFrames {
                let toRead = AVAudioFrameCount(min(totalFrames - frameIdx, Int(chunkSize)))
                buffer.frameLength = 0
                do { try file.read(into: buffer, frameCount: toRead) } catch { break }
                guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { break }
                let n = Int(buffer.frameLength)
                for f in 0..<n {
                    let bucket = min(frameIdx / bucketFrames, resolution - 1)
                    for c in 0..<ch {
                        peaks[c][bucket] = max(peaks[c][bucket], abs(channelData[c][f]))
                    }
                    frameIdx += 1
                }
            }
        }

        // Filter to single channel if requested (before normalization so globalMax is per-clip).
        let result: [[Float]]
        if let chIdx = channelIndex, chIdx < peaks.count {
            result = [peaks[chIdx]]
        } else {
            result = peaks
        }

        if normalized {
            // Normalise all channels against the global max so relative levels are preserved
            // (e.g. a quiet rear channel stays visually quieter than the L/R mains).
            // Use a noise-floor threshold (~-120 dBFS) so channels with only floating-point
            // quantisation noise are treated as silent rather than blown up to full scale.
            let kSilenceThreshold: Float = 1e-6
            let globalMax = result.compactMap { $0.max() }.max() ?? 0
            var normResult = result
            if globalMax > kSilenceThreshold {
                for c in 0..<normResult.count {
                    let chMax = normResult[c].max() ?? 0
                    if chMax > kSilenceThreshold {
                        normResult[c] = normResult[c].map { $0 / globalMax }
                    } else {
                        normResult[c] = [Float](repeating: 0, count: resolution)
                    }
                }
            }
            WaveformCache.shared.set(peaks: normResult, audioURL: url, startSample: startSample,
                                     lengthSamples: lengthSamples, resolution: resolution,
                                     channelIndex: channelIndex, normalized: true, sparse: sparse)
            return normResult
        } else {
            // Return raw linear amplitudes — caller is responsible for cross-clip normalization.
            WaveformCache.shared.set(peaks: result, audioURL: url, startSample: startSample,
                                     lengthSamples: lengthSamples, resolution: resolution,
                                     channelIndex: channelIndex, normalized: false, sparse: sparse)
            return result
        }
    }
}
