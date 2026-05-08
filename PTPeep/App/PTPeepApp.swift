import SwiftUI
import UniformTypeIdentifiers

@main
struct PTPeepApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("PTPeep") {
            AppContentView()
                .environmentObject(appState)
                .frame(minWidth: 640, idealWidth: 720,
                       minHeight: 480, idealHeight: 600)
                .onAppear { appDelegate.appState = appState }
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == "ptx" else { return }
                    appState.open(url: url)
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Session…") {
                    appState.showOpenPanel()
                }
                .keyboardShortcut("o")
            }
        }
    }
}

// MARK: - AppDelegate for Finder file-open events

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ptx" }) else { return }
        bringWindowForward(application)
        appState?.open(url: url)
    }

    // Clicking the Dock icon when all windows are closed reopens the main window.
    // Return false when no windows exist so SwiftUI creates a new one automatically;
    // return true (and handle manually) only when windows already exist.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        if app.windows.isEmpty { return false }  // let SwiftUI create a new window
        bringWindowForward(app)
        return true
    }

    private func bringWindowForward(_ app: NSApplication) {
        if let win = app.windows.first(where: { $0.isVisible }) ?? app.windows.first {
            win.makeKeyAndOrderFront(nil)
        }
        app.activate(ignoringOtherApps: true)
    }
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    @Published var session:    PTXSession?
    @Published var sessionURL: URL?
    @Published var isLoading   = false
    @Published var errorText:  String?

    private var openTask: Task<Void, Never>?

    func close() {
        openTask?.cancel()
        openTask    = nil
        session     = nil
        sessionURL  = nil
        isLoading   = false
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ptx") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        panel.prompt               = "Open"
        panel.message              = "Select a Pro Tools session file"
        // Use non-blocking begin() — runModal() blocks the main thread and
        // causes the panel to become unresponsive when called from SwiftUI.
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url: url)
        }
    }

    func open(url: URL) {
        openTask?.cancel()
        openTask = Task { await _open(url: url) }
    }

    private func _open(url: URL) async {
        isLoading  = true
        errorText  = nil
        sessionURL = url

        // Parse binary
        var parsed: PTXSession
        do {
            parsed = try PTXParser.parse(url: url)
        } catch {
            errorText = error.localizedDescription
            isLoading = false
            return
        }

        guard !Task.isCancelled else { isLoading = false; return }

        // Resolve audio files
        PTXParser.resolveAudioFiles(session: &parsed, sessionURL: url)

        // Publish initial result so UI appears immediately
        session   = parsed
        isLoading = false

        // Ensure the window is visible — handles the case where the user closed
        // the macOS window then opened a new session via menu or Finder.
        (NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first)?
            .makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Augment with PTSL in background (no-op if PT not connected)
        await PTSLSessionInfo.shared.augment(session: &parsed)

        // Discard PTSL result if this open was superseded by close or a newer open
        guard !Task.isCancelled, sessionURL == url else { return }
        session = parsed

        // Write clip log for diagnostics
        PTXParser.writeClipLog(session: parsed, sessionURL: url)
    }

    func openInProTools() {
        guard let url = sessionURL else { return }
        let fm = FileManager.default
        let candidates = [
            "/Applications/Pro Tools.app",
            "/Applications/Avid/Pro Tools.app",
        ]
        guard let appURL = candidates.map(URL.init(fileURLWithPath:))
                                     .first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: .init(),
            completionHandler: nil
        )
    }
}

// MARK: - App content

struct AppContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let session = appState.session, let url = appState.sessionURL {
            SessionInspectorView(
                session:          session,
                sessionURL:       url,
                onOpenInProTools: { appState.openInProTools() },
                onClose: { appState.close() }
            )
        } else if appState.isLoading {
            ProgressView("Parsing session…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            dropZone
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Open a Pro Tools session")
                .font(.title3)
                .foregroundStyle(.secondary)
            if let err = appState.errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Choose Session…") { appState.showOpenPanel() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "ptx" else { return }
                Task { @MainActor in await appState.open(url: url) }
            }
            return true
        }
    }
}
