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
    func play(clip: PTXClip, url: URL, sampleRate: Double, fromFraction: Double = 0) {
        stop()

        // Apply the currently-stored device preference before starting
        let prefUID = UserDefaults.standard.string(forKey: "audioOutputDeviceUID") ?? ""
        if !prefUID.isEmpty, let deviceID = AudioDeviceManager.deviceID(forUID: prefUID) {
            if engine.isRunning { engine.stop() }
            AudioDeviceManager.setEngineOutputDevice(engine, deviceID: deviceID)
        }

        guard let file = try? AVAudioFile(forReading: url) else { return }

        if !engine.isRunning { try? engine.start() }

        let clampedFrac = max(0, min(0.9999, fromFraction))
        seekFraction  = clampedFrac
        fullDurSec    = max(Double(clip.lengthSamples) / max(sampleRate, 1), 0.001)

        let seekSamples     = Int64(clampedFrac * Double(clip.lengthSamples))
        let remainingSamples = max(clip.lengthSamples - seekSamples, 0)
        clipDurSec           = max(Double(remainingSamples) / max(sampleRate, 1), 0.001)

        let startFrame = AVAudioFramePosition(clip.sourceOffset + seekSamples)
        let frameCount = AVAudioFrameCount(remainingSamples)

        // Single-channel extraction for multichannel interleaved files.
        // If clip name has ".AN" suffix and the file has more than one channel,
        // read the segment into a buffer and memcpy just that channel into a mono buffer.
        var scheduled = false
        let chIdx = AudioPlayer.channelIndex(fromClipName: clip.name)
        let fileCh = Int(file.processingFormat.channelCount)
        if let ch = chIdx, fileCh > 1, ch < fileCh,
           let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: frameCount) {
            file.framePosition = startFrame
            if (try? file.read(into: srcBuf, frameCount: frameCount)) != nil,
               srcBuf.frameLength > 0,
               let channelData = srcBuf.floatChannelData,
               let monoFmt = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate,
                                           channels: 1),
               let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFmt,
                                              frameCapacity: srcBuf.frameLength) {
                monoBuf.frameLength = srcBuf.frameLength
                memcpy(monoBuf.floatChannelData![0], channelData[ch],
                       Int(srcBuf.frameLength) * MemoryLayout<Float>.size)
                playerNode.scheduleBuffer(monoBuf, at: nil)
                scheduled = true
            }
        }
        if !scheduled {
            playerNode.scheduleSegment(file, startingFrame: startFrame,
                                       frameCount: frameCount, at: nil)
        }
        playerNode.play()

        isPlaying        = true
        playingClip      = clip
        playbackFraction = clampedFrac

        // Timer to stop at clip end
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + clipDurSec, execute: work)

        // ~60 fps ticker for playhead position (absolute fraction within full clip)
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, let nodeTime = self.playerNode.lastRenderTime,
                  nodeTime.isSampleTimeValid,
                  let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime),
                  playerTime.isSampleTimeValid,
                  frameCount > 0 else { return }
            let elapsed = Double(playerTime.sampleTime) / file.processingFormat.sampleRate
            self.playbackFraction = max(0, min(1, self.seekFraction + elapsed / self.fullDurSec))
        }
    }

    func stop() {
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
    }

    // MARK: - Region playback

    /// Plays a multi-clip region: one stitched buffer per track, all started simultaneously.
    /// Clips within each track are separated by silence to preserve their timeline spacing.
    /// Safe to call from any thread; all AVAudioEngine work is dispatched to the main queue.
    func playRegion(_ region: PlayRegion) {
        stop()

        guard !region.segments.isEmpty else { return }

        // Apply stored output device preference
        let prefUID = UserDefaults.standard.string(forKey: "audioOutputDeviceUID") ?? ""
        if !prefUID.isEmpty, let deviceID = AudioDeviceManager.deviceID(forUID: prefUID) {
            if engine.isRunning { engine.stop() }
            AudioDeviceManager.setEngineOutputDevice(engine, deviceID: deviceID)
        }

        // Common format: 48 kHz mono float32 non-interleaved (lowest common denominator).
        // All clip buffers are read via AVAudioFile.processingFormat (always float32),
        // so channel extraction and format bridging is handled per-clip below.
        let sr = region.sampleRate > 0 ? region.sampleRate : 48000
        guard let monoFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }

        let regionFrames = AVAudioFrameCount(region.endSample - region.startSample)
        guard regionFrames > 0 else { return }

        // Build one stitched mono buffer per track segment.
        var readyNodes: [AVAudioPlayerNode] = []

        for segment in region.segments {
            guard let stitched = AVAudioPCMBuffer(pcmFormat: monoFmt,
                                                  frameCapacity: regionFrames) else { continue }
            stitched.frameLength = regionFrames
            // Zero-fill (silence)
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
                // Offset into the stitched buffer where this clip starts
                let bufOffset  = Int(clipStart - region.startSample)
                // Offset into the source file (sourceOffset + trim into region)
                let fileStart  = AVAudioFramePosition(clip.sourceOffset + (clipStart - clip.startSample))

                guard let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                     frameCapacity: clipFrames) else { continue }
                file.framePosition = fileStart
                guard (try? file.read(into: srcBuf, frameCount: clipFrames)) != nil,
                      srcBuf.frameLength > 0,
                      let channelData = srcBuf.floatChannelData else { continue }

                // Pick the right channel: .AN suffix → 0-based index; fallback to ch 0
                let chIdx = AudioPlayer.channelIndex(fromClipName: clip.name) ?? 0
                let srcCh = min(chIdx, Int(srcBuf.format.channelCount) - 1)

                if let dst = stitched.floatChannelData?[0] {
                    let count = Int(min(srcBuf.frameLength, regionFrames - AVAudioFrameCount(bufOffset)))
                    memcpy(dst + bufOffset, channelData[srcCh], count * MemoryLayout<Float>.size)
                    wroteAny = true
                }
            }

            guard wroteAny else { continue }

            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: gainNode, format: monoFmt)
            node.scheduleBuffer(stitched, at: nil)
            readyNodes.append(node)
        }

        guard !readyNodes.isEmpty else { return }

        if !engine.isRunning { try? engine.start() }

        // Synchronise all nodes to the same host time anchor (~10 ms from now)
        let startTime = AVAudioTime(hostTime: mach_absolute_time() + msToHostTicks(20))
        for node in readyNodes { node.play(at: startTime) }

        regionNodes     = readyNodes
        isPlaying       = true
        isPlayingRegion = true

        let durSec = Double(regionFrames) / sr
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + durSec, execute: work)
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
                             sampleRate: Double, resolution: Int = 500,
                             channelIndex: Int? = nil) async -> [[Float]] {
        // Cache hit?
        if let cached = WaveformCache.shared.get(audioURL: url, startSample: startSample,
                                                  lengthSamples: lengthSamples, resolution: resolution,
                                                  channelIndex: channelIndex) {
            return cached
        }

        guard let file = try? AVAudioFile(forReading: url) else { return [] }

        // processingFormat is guaranteed float32 non-interleaved with the correct channel count.
        let fmt = file.processingFormat
        let ch  = Int(fmt.channelCount)

        let totalFrames  = Int(lengthSamples)
        let bucketFrames = max(1, totalFrames / resolution)
        let chunkSize    = AVAudioFrameCount(min(totalFrames, 65536))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkSize) else { return [] }

        file.framePosition = startSample   // seek to clip start

        var peaks    = [[Float]](repeating: [Float](repeating: 0, count: resolution), count: ch)
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

        // Normalise all channels against the global max so relative levels are preserved
        // (e.g. a quiet rear channel stays visually quieter than the L/R mains).
        // Use a noise-floor threshold (~-120 dBFS) so channels with only floating-point
        // quantisation noise are treated as silent rather than blown up to full scale.
        let kSilenceThreshold: Float = 1e-6
        let globalMax = peaks.compactMap { $0.max() }.max() ?? 0
        if globalMax > kSilenceThreshold {
            for c in 0..<ch {
                let chMax = peaks[c].max() ?? 0
                if chMax > kSilenceThreshold {
                    peaks[c] = peaks[c].map { $0 / globalMax }
                } else {
                    peaks[c] = [Float](repeating: 0, count: resolution)
                }
            }
        }
        // Filter to single channel if requested
        let result: [[Float]]
        if let ch = channelIndex, ch < peaks.count {
            result = [peaks[ch]]
        } else {
            result = peaks
        }

        WaveformCache.shared.set(peaks: result, audioURL: url, startSample: startSample,
                                 lengthSamples: lengthSamples, resolution: resolution,
                                 channelIndex: channelIndex)
        return result
    }
}
