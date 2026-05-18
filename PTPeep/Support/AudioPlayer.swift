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
    @Published var isPlaying: Bool = false
    @Published var playingClip: PTXClip? = nil
    @Published var playbackFraction: Double = 0   // 0…1 within the clip's duration

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var stopWorkItem: DispatchWorkItem?
    private var ticker:       Timer?
    private var clipDurSec:   Double = 1   // remaining scheduled duration (for stop timer)
    private var fullDurSec:   Double = 1   // full clip duration (for playbackFraction math)
    private var seekFraction: Double = 0   // 0..1 within clip where playback started

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
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

        playerNode.scheduleSegment(file, startingFrame: startFrame,
                                   frameCount: frameCount, at: nil)
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
        isPlaying        = false
        playingClip      = nil
        playbackFraction = 0
    }

    // MARK: - Waveform loading

    /// Reads PCM peaks for the clip region in the source file, per channel.
    /// Returns one `[Float]` per channel (mono → 1, stereo → 2, etc.), each normalised 0…1.
    /// Runs off the main actor.
    static func loadWaveform(url: URL, startSample: Int64, lengthSamples: Int64,
                             sampleRate: Double, resolution: Int = 500) async -> [[Float]] {
        // Probe channel count before configuring the reader.
        // AVAudioFile is the most reliable way to read the source format.
        let ch = max(Int((try? AVAudioFile(forReading: url))?.fileFormat.channelCount ?? 1), 1)

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }

        // AVNumberOfChannelsKey must be set explicitly; without it AVAssetReaderTrackOutput
        // may downmix to mono regardless of the source channel count.
        let outputSettings: [String: Any] = [
            AVFormatIDKey:              kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:     32,
            AVLinearPCMIsFloatKey:      true,
            AVLinearPCMIsBigEndianKey:  false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey:      ch
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        // Seek to clip region
        let sr = CMTimeScale(max(sampleRate, 1).rounded())
        reader.timeRange = CMTimeRange(
            start:    CMTime(value: startSample,           timescale: sr),
            duration: CMTime(value: max(lengthSamples, 1), timescale: sr)
        )
        guard reader.startReading() else { return [] }

        // Bucket PCM frames into `resolution` peak bins, per channel
        let totalFrames  = Int(lengthSamples)
        let bucketFrames = max(1, totalFrames / resolution)
        var peaks        = [[Float]](repeating: [Float](repeating: 0, count: resolution), count: ch)
        var frameIdx     = 0

        while let sampleBuf = output.copyNextSampleBuffer() {
            guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuf) else { continue }
            let byteLen = CMBlockBufferGetDataLength(blockBuf)
            let count   = byteLen / MemoryLayout<Float>.size
            var data    = [Float](repeating: 0, count: count)
            CMBlockBufferCopyDataBytes(blockBuf, atOffset: 0, dataLength: byteLen, destination: &data)

            var i = 0
            while i + ch <= count {
                let bucket = min(frameIdx / bucketFrames, resolution - 1)
                for c in 0..<ch {
                    peaks[c][bucket] = max(peaks[c][bucket], abs(data[i + c]))
                }
                frameIdx += 1
                i += ch
            }
        }

        // Normalise each channel independently to 0…1
        for c in 0..<ch {
            let maxPeak = peaks[c].max() ?? 0
            if maxPeak > 0 { peaks[c] = peaks[c].map { $0 / maxPeak } }
        }
        return peaks
    }
}
