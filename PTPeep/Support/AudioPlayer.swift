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
    private var clipStartSec: Double = 0
    private var clipDurSec:   Double = 1

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

    func play(clip: PTXClip, url: URL, sampleRate: Double) {
        stop()

        // Apply the currently-stored device preference before starting
        let prefUID = UserDefaults.standard.string(forKey: "audioOutputDeviceUID") ?? ""
        if !prefUID.isEmpty, let deviceID = AudioDeviceManager.deviceID(forUID: prefUID) {
            if engine.isRunning { engine.stop() }
            AudioDeviceManager.setEngineOutputDevice(engine, deviceID: deviceID)
        }

        guard let file = try? AVAudioFile(forReading: url) else { return }

        if !engine.isRunning { try? engine.start() }

        let startSec  = Double(clip.sourceOffset) / max(sampleRate, 1)
        let durSec    = Double(clip.lengthSamples) / max(sampleRate, 1)
        clipStartSec  = startSec
        clipDurSec    = max(durSec, 0.001)

        let startFrame = AVAudioFramePosition(clip.sourceOffset)
        let frameCount = AVAudioFrameCount(clip.lengthSamples)

        playerNode.scheduleSegment(file, startingFrame: startFrame,
                                   frameCount: frameCount, at: nil)
        playerNode.play()

        isPlaying        = true
        playingClip      = clip
        playbackFraction = 0

        // Timer to stop at clip end
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + durSec, execute: work)

        // ~60 fps ticker for playhead position
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, let nodeTime = self.playerNode.lastRenderTime,
                  nodeTime.isSampleTimeValid,
                  let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime),
                  playerTime.isSampleTimeValid,
                  frameCount > 0 else { return }
            let elapsed = Double(playerTime.sampleTime) / file.processingFormat.sampleRate
            self.playbackFraction = max(0, min(1, elapsed / self.clipDurSec))
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

    /// Reads PCM peaks for the clip region in the source file.
    /// Returns `resolution` Float values in 0…1. Runs off the main actor.
    static func loadWaveform(url: URL, startSample: Int64, lengthSamples: Int64,
                             sampleRate: Double, resolution: Int = 500) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }

        let outputSettings: [String: Any] = [
            AVFormatIDKey:           kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:  32,
            AVLinearPCMIsFloatKey:   true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        // Channel count for interleaved stride
        var channelCount = 1
        if let descs = try? await track.load(.formatDescriptions),
           let basic = descs.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0) }) {
            channelCount = Int(basic.pointee.mChannelsPerFrame)
        }
        let ch = max(channelCount, 1)

        // Seek to clip region
        let sr = CMTimeScale(max(sampleRate, 1).rounded())
        reader.timeRange = CMTimeRange(
            start:    CMTime(value: startSample,           timescale: sr),
            duration: CMTime(value: max(lengthSamples, 1), timescale: sr)
        )
        guard reader.startReading() else { return [] }

        // Bucket PCM frames into `resolution` peak bins
        let totalFrames  = Int(lengthSamples)
        let bucketFrames = max(1, totalFrames / resolution)
        var peaks        = [Float](repeating: 0, count: resolution)
        var frameIdx     = 0

        while let sampleBuf = output.copyNextSampleBuffer() {
            guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuf) else { continue }
            let byteLen = CMBlockBufferGetDataLength(blockBuf)
            let count   = byteLen / MemoryLayout<Float>.size
            var data    = [Float](repeating: 0, count: count)
            CMBlockBufferCopyDataBytes(blockBuf, atOffset: 0, dataLength: byteLen, destination: &data)

            var i = 0
            while i + ch <= count {
                var framePeak: Float = 0
                for c in 0..<ch { framePeak = max(framePeak, abs(data[i + c])) }
                let bucket = min(frameIdx / bucketFrames, resolution - 1)
                peaks[bucket] = max(peaks[bucket], framePeak)
                frameIdx += 1
                i += ch
            }
        }

        // Normalise to 0…1
        let maxPeak = peaks.max() ?? 0
        if maxPeak > 0 { peaks = peaks.map { $0 / maxPeak } }
        return peaks
    }
}
