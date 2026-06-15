import SwiftUI
import AVFoundation

/// Root of the floating Video window. Follows the active session and matches the
/// main window's color mode, mirroring `AudioFilesWindow`.
struct VideoWindow: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("colorMode") private var colorMode: ColorMode = .dark

    var body: some View {
        ZStack {
            if let model = appState.activeVideoModel() {
                VideoWindowContent(model: model)
                    .id(appState.selectedTabID)   // re-init when the session switches
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No session open")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(colorMode.colorScheme)
        .background(WindowCloseObserver { appState.videoWindowDetached = false })
    }
}

private struct VideoWindowContent: View {
    @ObservedObject var model: VideoPlayerModel
    @State private var spotText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: model.player)
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            controls
        }
        .onAppear { model.autoLocateIfNeeded() }
        .onChange(of: model.cursorSample) { _ in model.seekToCursor() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(model.videoURL == nil)

            Text(positionTC)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(model.videoURL == nil ? .secondary : .primary)

            Spacer()

            HStack(spacing: 4) {
                Text("Spot to")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("HH:MM:SS:FF", text: $spotText, onCommit: commitSpot)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 104)
                    .disabled(model.videoURL == nil)
            }

            Button("Load Video…") { loadVideo() }
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Current cursor position shown as session timecode (frame-based).
    private var positionTC: String {
        formatTC(Double(model.cursorSample) / max(model.sampleRate, 1), fps: model.frameRate)
    }

    private func commitSpot() {
        let text = spotText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
              let frac = TimelineNav.parseTCFrac(text, fps: model.frameRate,
                                                 totalSamples: Double(model.totalSamples),
                                                 sampleRate: model.sampleRate)
        else { return }
        let sample = Int64(frac * Double(model.totalSamples))
        model.spot(currentFrameToSessionSample: sample)
        spotText = ""
    }

    private func loadVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.load(url: url)
        }
    }
}

/// A resizable AVPlayerLayer-backed surface (our own chrome, unlike AVPlayerView).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PlayerNSView)?.playerLayer.player = player
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = playerLayer
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
