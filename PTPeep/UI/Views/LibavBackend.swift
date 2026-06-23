import AppKit
import Foundation

/// Frame-accurate `VideoBackend` built on the in-process libav decoder + frame cache, rendered
/// by an `AVSampleBufferDisplayLayer` deck. Replaces VLCKit: DNxHD/DNxHR and everything else
/// decode in-process with exact seeking and no VideoToolbox cold-start. Main-app only.
@MainActor
final class LibavBackend: VideoBackend {
    private let url: URL
    private let deck = VideoDeckView()
    private var cache: LibavFrameCache?
    private var fps: Double = 24
    private var totalFrames = 0
    private var currentFrame = 0
    private var playTimer: Timer?

    var onReady: ((Double) -> Void)?
    var onFail: ((String?) -> Void)?

    init(url: URL) { self.url = url }

    var currentSeconds: Double { fps > 0 ? Double(currentFrame) / fps : 0 }

    func load(url: URL) {
        Task { [weak self] in
            let decoder = await LibavDecoder.make(url: url)
            await MainActor.run {
                guard let self else { return }
                guard let decoder else { self.onFail?(nil); return }
                let cache = LibavFrameCache(decoder: decoder)
                self.cache = cache
                self.fps = decoder.fps > 0 ? decoder.fps : 24
                self.totalFrames = decoder.totalFrames
                cache.primePrefetch(around: 0)
                self.showFrame(0)
                self.onReady?(decoder.duration.seconds.isFinite ? decoder.duration.seconds : 0)
            }
        }
    }

    func makeView() -> NSView { deck }

    /// Frame-accurate seek: round to the nearest frame and display it immediately.
    func seek(toSeconds t: Double) {
        guard fps > 0 else { return }
        showFrame(Int((t * fps).rounded()))
    }

    /// Standalone play (the Video window's own Play button) — advances frames on a timer.
    /// Transport playback drives `seek(toSeconds:)` from the session playhead instead.
    func play() {
        guard playTimer == nil, fps > 0, totalFrames > 0 else { return }
        let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            guard let self else { return }
            let next = self.currentFrame + 1
            if next >= self.totalFrames { self.pause(); return }
            self.showFrame(next)
        }
        RunLoop.main.add(t, forMode: .common)
        playTimer = t
    }

    func pause() { playTimer?.invalidate(); playTimer = nil }

    private func showFrame(_ index: Int) {
        guard let cache, totalFrames > 0 else { return }
        let clamped = max(0, min(index, totalFrames - 1))
        currentFrame = clamped
        if let sb = cache.cachedFrame(at: clamped) { deck.show(sb) }
    }
}
