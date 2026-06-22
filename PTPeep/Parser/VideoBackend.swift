import AVFoundation
import AppKit
import CoreMedia

/// Abstracts the movie decoder/renderer behind the Video window so we can fall back
/// from AVFoundation (system codecs only) to a bundled engine (VLCKit) for codecs
/// macOS can't decode — e.g. Avid DNxHD/DNxHR. Driven by `VideoPlayerModel`.
///
/// This file is shared with the Quick Look extension, so it must reference only
/// AVFoundation/AppKit — never VLCKit. The VLC backend lives in a main-app-only file
/// and is supplied via `VideoPlayerModel.makeFallbackBackend`.
@MainActor
protocol VideoBackend: AnyObject {
    /// Current playhead position in seconds.
    var currentSeconds: Double { get }
    func load(url: URL)
    func play()
    func pause()
    /// Seek as exactly as the engine allows.
    func seek(toSeconds: Double)
    /// The picture surface (a fresh view per call).
    func makeView() -> NSView
    /// Asset is ready to play; argument is its duration in seconds.
    var onReady: ((Double) -> Void)? { get set }
    /// Backend cannot decode/play the asset. Argument is the video codec FourCC if
    /// known (e.g. "AVdn" for DNxHD/DNxHR).
    var onFail: ((String?) -> Void)? { get set }
}

/// Native, hardware-accelerated path for codecs macOS supports (ProRes, H.264, HEVC).
/// Probes decodability before committing to playback so undecodable files (DNxHD on a
/// machine with no system decoder) report failure instead of showing a black frame.
@MainActor
final class AVFoundationBackend: VideoBackend {
    let player = AVPlayer()
    var onReady: ((Double) -> Void)?
    var onFail: ((String?) -> Void)?

    var currentSeconds: Double {
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : 0
    }

    func load(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        Task { [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let vtracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            var decodable = playable && !vtracks.isEmpty
            var fourCC: String?
            if let track = vtracks.first {
                if let dec = try? await track.load(.isDecodable) { decodable = decodable && dec }
                if let fmts = try? await track.load(.formatDescriptions), let f = fmts.first {
                    fourCC = Self.fourCCString(CMFormatDescriptionGetMediaSubType(f))
                }
            }
            let dur = (try? await asset.load(.duration)) ?? .zero
            await MainActor.run {
                guard let self else { return }
                if decodable {
                    AppLog.shared.log("[Video] AVFoundation decoding \(fourCC ?? "?") (\(url.lastPathComponent))")
                    self.player.replaceCurrentItem(with: item)
                    self.onReady?(CMTimeGetSeconds(dur))
                } else {
                    self.onFail?(fourCC)
                }
            }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(toSeconds t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func makeView() -> NSView {
        let v = PlayerLayerNSView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    /// Render a FourCharCode codec type (e.g. 'AVdn') as a trimmed string.
    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return (String(bytes: bytes, encoding: .macOSRoman) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// An AVPlayerLayer-backed surface (our own chrome, unlike AVPlayerView).
    final class PlayerLayerNSView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = playerLayer
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
