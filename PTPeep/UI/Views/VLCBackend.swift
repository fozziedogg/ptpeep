import AppKit
import VLCKitSPM

/// VLCKit-backed `VideoBackend` for codecs AVFoundation can't decode (Avid DNxHD/DNxHR,
/// MXF, …). libVLC bundles its own FFmpeg decoders, so it plays the same files VLC does.
///
/// Main-app only — never linked into the Quick Look extension. Supplied to the shared
/// `VideoPlayerModel` via `makeFallbackBackend`, so the shared layer never names VLCKit.
@MainActor
final class VLCBackend: NSObject, VideoBackend {
    private let player = VLCMediaPlayer()
    private let url: URL
    private let delegateShim = PlayerDelegate()
    private var view: NSView?
    private var pendingURL: URL?
    private var started = false
    private var didReportReady = false
    private var didReportLength = false

    var onReady: ((Double) -> Void)?
    var onFail: ((String?) -> Void)?

    init(url: URL) {
        self.url = url
        super.init()
        delegateShim.owner = self
        player.delegate = delegateShim
        // Picture reference only — the session's audio is handled separately.
        player.audio?.isMuted = true
    }

    var currentSeconds: Double { Double(player.time.intValue) / 1000.0 }

    func load(url: URL) {
        player.media = VLCMedia(url: url)
        pendingURL = url
        started = false
        // VLC needs a drawable to render into. If the surface already exists, start now;
        // otherwise defer to makeView() (the common path: the model swaps to this backend
        // and calls load() before SwiftUI creates the surface).
        if view != nil { startIfNeeded() }
    }

    private func startIfNeeded() {
        guard view != nil, pendingURL != nil, !started else { return }
        started = true
        // Start decoding so the first frame renders and length becomes known; we pause
        // once it's ready (the model treats the window as paused / locked to the cursor).
        player.play()
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(toSeconds t: Double) {
        player.time = VLCTime(int: Int32((t * 1000).rounded()))
    }

    func makeView() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        player.drawable = v
        view = v
        startIfNeeded()   // surface now exists — begin playback if load() was already called
        return v
    }

    private var mediaLengthSeconds: Double {
        Double(player.media?.length.intValue ?? 0) / 1000.0
    }

    // MARK: Delegate callbacks (hopped onto the main actor by PlayerDelegate)

    fileprivate func handleStateChanged() {
        switch player.state {
        case .error:
            AppLog.shared.log("[Video] VLC playback error for \(url.lastPathComponent)")
            if !didReportReady { didReportReady = true; onFail?(nil) }
        case .playing, .buffering, .esAdded:
            reportReadyIfNeeded()
        default:
            break
        }
    }

    fileprivate func handleTimeChanged() { refreshLengthIfNeeded() }

    /// First playable frame: report ready (initial cursor seek) and hold on the frame.
    private func reportReadyIfNeeded() {
        guard !didReportReady else { return }
        didReportReady = true
        let len = mediaLengthSeconds
        if len > 0 { didReportLength = true }
        player.pause()
        onReady?(len)
    }

    /// Duration often isn't known at the first frame; refresh it once libVLC reports it.
    private func refreshLengthIfNeeded() {
        guard didReportReady, !didReportLength else { return }
        let len = mediaLengthSeconds
        guard len > 0 else { return }
        didReportLength = true
        onReady?(len)
    }
}

/// Nonisolated shim so VLCKit's `@objc` delegate callbacks (which may arrive off the main
/// thread) don't cross into the main-actor-isolated `VLCBackend`. Forwards onto the main actor.
private final class PlayerDelegate: NSObject, VLCMediaPlayerDelegate {
    weak var owner: VLCBackend?

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let owner = self.owner
        Task { @MainActor in owner?.handleStateChanged() }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let owner = self.owner
        Task { @MainActor in owner?.handleTimeChanged() }
    }
}
