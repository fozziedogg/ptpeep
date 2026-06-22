import AVFoundation
import Combine
import Foundation

/// Per-session state for the Video window: the playback backend, the picture↔session
/// timecode offset (anchor), and the timeline cursor (written by the inspector).
/// Owned by `AppState` (keyed by tab id), mirroring `AudioFilesModel`.
///
/// Playback goes through a `VideoBackend`: AVFoundation for codecs macOS can decode
/// (ProRes/H.264/HEVC), falling back to a bundled VLCKit engine for the rest (DNxHD,
/// MXF, …). The fallback is injected via `makeFallbackBackend` so this shared file —
/// also compiled into the Quick Look extension — never references VLCKit.
@MainActor
final class VideoPlayerModel: ObservableObject {
    let tabID: UUID
    let sessionURL: URL
    let sampleRate: Double
    let frameRate: Double
    let totalSamples: Int64
    let videoClipStartSample: Int64
    let videoClipName: String

    /// The active playback engine. Swaps from AVFoundation to the fallback when a file
    /// can't be decoded natively; the window re-creates its surface when this changes.
    @Published private(set) var backend: VideoBackend
    @Published var videoURL: URL?
    @Published var duration: Double = 0          // seconds
    @Published var isPlaying = false
    /// Set when no available backend can decode the movie (codec-aware guidance).
    @Published var loadError: String?
    /// Timeline cursor in absolute session samples (written by SessionInspectorView).
    @Published var cursorSample: Int64 = 0
    /// Absolute session sample at which movie time 0 sits — the spotting offset.
    @Published var anchorSample: Int64

    /// Supplies a bundled fallback backend (VLCKit) for codecs AVFoundation can't decode.
    /// Set once by the main app at launch; left nil in the Quick Look extension.
    static var makeFallbackBackend: (@MainActor (URL) -> VideoBackend)?

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
        self.backend = AVFoundationBackend()
        configure(backend)
    }

    /// Movie time (seconds) the cursor maps to, clamped to the loaded duration.
    var movieTimeForCursor: Double {
        let t = Double(cursorSample - anchorSample) / max(sampleRate, 1)
        guard duration > 0 else { return max(t, 0) }
        return min(max(t, 0), duration)
    }

    // MARK: Loading

    func load(url: URL) {
        loadError = nil
        videoURL = url
        isPlaying = false
        duration = 0
        // Always probe natively first; fall back only when AVFoundation can't decode.
        let av = AVFoundationBackend()
        configure(av)
        backend = av
        av.load(url: url)
    }

    private func configure(_ b: VideoBackend) {
        b.onReady = { [weak self] dur in
            guard let self else { return }
            self.duration = dur
            self.seekToCursor(force: true)
        }
        b.onFail = { [weak self] fourCC in
            self?.handleDecodeFailure(fourCC: fourCC)
        }
    }

    /// AVFoundation couldn't decode the file. Try the bundled fallback if available;
    /// otherwise (Quick Look, or the fallback also failed) surface codec-aware guidance.
    private func handleDecodeFailure(fourCC: String?) {
        if backend is AVFoundationBackend,
           let make = Self.makeFallbackBackend,
           let url = videoURL {
            let fb = make(url)
            configure(fb)
            backend = fb
            fb.load(url: url)
            return
        }
        loadError = Self.message(forFourCC: fourCC)
    }

    static func message(forFourCC fourCC: String?) -> String {
        if fourCC == "AVdn" {
            return "This movie uses Avid DNxHD/DNxHR, which can't be decoded here. "
                 + "Transcode the picture to ProRes or H.264 to view it."
        }
        let code = fourCC.map { " (\($0))" } ?? ""
        return "This movie's video codec\(code) can't be decoded here. "
             + "Transcode the picture to ProRes or H.264 to view it."
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
        guard videoURL != nil, loadError == nil else { return }
        if isPlaying { backend.pause() } else { backend.play() }
        isPlaying.toggle()
    }

    func seekToCursor(force: Bool = false) {
        guard videoURL != nil, loadError == nil, force || !isPlaying else { return }
        backend.seek(toSeconds: movieTimeForCursor)
    }

    // MARK: Spotting

    /// Spot the picture so its current frame lands at the given absolute session
    /// sample (defines the picture↔session offset).
    func spot(currentFrameToSessionSample s: Int64) {
        let movieT = backend.currentSeconds
        anchorSample = s - Int64(movieT * sampleRate)
    }
}
