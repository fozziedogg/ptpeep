import AVFoundation
import Combine
import Foundation

/// Per-session state for the Video window: the AVPlayer, the picture↔session
/// timecode offset (anchor), and the timeline cursor (written by the inspector).
/// Owned by `AppState` (keyed by tab id), mirroring `AudioFilesModel`.
@MainActor
final class VideoPlayerModel: ObservableObject {
    let tabID: UUID
    let sessionURL: URL
    let sampleRate: Double
    let frameRate: Double
    let totalSamples: Int64
    let videoClipStartSample: Int64
    let videoClipName: String

    @Published var player = AVPlayer()
    @Published var videoURL: URL?
    @Published var duration: Double = 0          // seconds
    @Published var isPlaying = false
    /// Timeline cursor in absolute session samples (written by SessionInspectorView).
    @Published var cursorSample: Int64 = 0
    /// Absolute session sample at which movie time 0 sits — the spotting offset.
    @Published var anchorSample: Int64

    private var didAutoLocate = false

    init(tabID: UUID, session: PTXSession, sessionURL: URL) {
        self.tabID = tabID
        self.sessionURL = sessionURL
        self.sampleRate = session.sampleRateValue
        self.frameRate = session.frameRate
        self.totalSamples = session.sessionLengthSamples ?? 1
        let videoClip = session.tracks
            .first { $0.type == .video && !$0.clips.isEmpty }?
            .clips.first
        let start = videoClip?.startSample ?? 0
        self.videoClipStartSample = start
        self.anchorSample = start
        self.videoClipName = videoClip.map { $0.sourceFile.isEmpty ? $0.name : $0.sourceFile } ?? ""
    }

    /// Movie time (seconds) the cursor maps to, clamped to the loaded duration.
    var movieTimeForCursor: Double {
        let t = Double(cursorSample - anchorSample) / max(sampleRate, 1)
        guard duration > 0 else { return max(t, 0) }
        return min(max(t, 0), duration)
    }

    // MARK: Loading

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        videoURL = url
        isPlaying = false
        Task { [weak self] in
            let dur = (try? await item.asset.load(.duration)) ?? .zero
            await MainActor.run {
                guard let self else { return }
                self.duration = CMTimeGetSeconds(dur)
                self.seekToCursor(force: true)
            }
        }
    }

    /// Find the session's movie near the .ptx by the video clip name (once).
    func autoLocateIfNeeded() {
        guard !didAutoLocate, videoURL == nil, !videoClipName.isEmpty else { return }
        didAutoLocate = true
        let stem = Self.stem(of: videoClipName)
        let exts: Set<String> = ["mov", "mp4", "m4v", "mxf"]
        let dir = sessionURL.deletingLastPathComponent()
        let folders = [dir,
                       dir.appendingPathComponent("Video Files"),
                       dir.appendingPathComponent("Video")]
        let fm = FileManager.default
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else { continue }
            if let match = items.first(where: { url in
                exts.contains(url.pathExtension.lowercased())
                && Self.stem(of: url.deletingPathExtension().lastPathComponent).hasPrefix(stem)
            }) {
                load(url: match)
                return
            }
        }
    }

    /// Strip a trailing "_<digits>" (channel/part suffix) for looser file matching.
    private static func stem(of name: String) -> String {
        name.replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seekToCursor(force: Bool = false) {
        guard videoURL != nil, force || !isPlaying else { return }
        player.seek(to: CMTime(seconds: movieTimeForCursor, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Spotting

    /// Spot the picture so its current frame lands at the given absolute session
    /// sample (defines the picture↔session offset).
    func spot(currentFrameToSessionSample s: Int64) {
        let movieT = CMTimeGetSeconds(player.currentTime())
        anchorSample = s - Int64(movieT * sampleRate)
    }
}
