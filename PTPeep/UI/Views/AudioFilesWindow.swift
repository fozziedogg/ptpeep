import SwiftUI

/// Root of the detached Audio Files floating window. Resolves the per-tab
/// `AudioFilesModel` from `AppState` and renders the shared table against it,
/// so the window stays live-synced with the main session.
struct AudioFilesWindow: View {
    let tabID: UUID?
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let tabID, let model = appState.existingAudioModel(for: tabID) {
            AudioFilesWindowContent(model: model)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Session closed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AudioFilesWindowContent: View {
    @ObservedObject var model: AudioFilesModel
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
        // Closing the window (or Re-dock) restores the inline tab.
        .onDisappear { model.isDetached = false }
    }

    private func redock() {
        model.isDetached = false
        dismiss()
    }
}
