import AVFoundation
import Combine

final class AudioPlayer: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var playingClip: PTXClip? = nil

    private var player: AVAudioPlayer?
    private var stopWorkItem: DispatchWorkItem?

    func play(clip: PTXClip, url: URL, sampleRate: Double) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        let startTime = Double(clip.sourceOffset) / sampleRate
        let duration  = Double(clip.lengthSamples) / sampleRate
        p.prepareToPlay()
        p.currentTime = startTime
        p.play()
        player      = p
        isPlaying   = true
        playingClip = clip

        let work = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        player?.stop()
        player      = nil
        isPlaying   = false
        playingClip = nil
    }
}
