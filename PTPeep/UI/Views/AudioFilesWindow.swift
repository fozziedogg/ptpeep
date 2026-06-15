import SwiftUI

/// Root of the detached Audio Files floating window. Follows the active session
/// (selected tab) and mirrors the main window's color mode. Closing it clears
/// the global detached flag, so the inline pane reattaches.
struct AudioFilesWindow: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("colorMode") private var colorMode: ColorMode = .dark

    var body: some View {
        ZStack {
            if let model = appState.activeAudioModel() {
                AudioFilesWindowContent(model: model)
                    .id(appState.selectedTabID)   // re-init when the session switches
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow")
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
        // Closing the window reattaches the pane. SwiftUI's onDisappear is
        // unreliable for window close, so observe the NSWindow directly.
        .background(WindowCloseObserver { appState.audioPaneDetached = false })
    }
}

/// Invokes `onClose` when the hosting NSWindow actually closes — reliable where
/// SwiftUI's `.onDisappear` is not for `Window` scenes.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let onClose = self.onClose
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.observe(window, onClose: onClose)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var token: NSObjectProtocol?
        func observe(_ window: NSWindow, onClose: @escaping @MainActor () -> Void) {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    onClose()
                    // One-shot: remove the observer after the window closes.
                    if let self, let token = self.token {
                        NotificationCenter.default.removeObserver(token)
                        self.token = nil
                    }
                }
            }
        }
    }
}

private struct AudioFilesWindowContent: View {
    @ObservedObject var model: AudioFilesModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("bwf.selectedFields") private var bwfFieldsRaw: String =
        BWFFieldKey.defaults.map(\.rawValue).joined(separator: ",")
    @AppStorage("af.followSelection") private var followClipSelection: Bool = true

    private var selectedFields: [BWFFieldKey] {
        bwfFieldsRaw.split(separator: ",").compactMap { BWFFieldKey(rawValue: String($0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Audio Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { redock() } label: {
                    Label("Re-dock", systemImage: "pip.exit")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Return the pane to the main window")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))

            Divider()

            AudioFilesTableView(
                audioFileNames: model.audioFileNames,
                resolvedLookup: model.resolvedLookup,
                bwfCache: model.bwfCache,
                selectedFields: selectedFields,
                sampleRate: model.sampleRate,
                frameRate: model.frameRate,
                highlightedFiles: model.highlightedFiles,
                isBWFLoading: model.isLoading,
                onClearFilter: { model.highlightedFiles.removeAll() },
                followClipSelection: $followClipSelection,
                bwfFieldsRaw: $bwfFieldsRaw
            )
        }
    }

    private func redock() {
        appState.audioPaneDetached = false
        dismiss()
    }
}
