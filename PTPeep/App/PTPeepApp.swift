import SwiftUI
import UniformTypeIdentifiers

@main
struct PTPeepApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("PTpeep") {
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
        // Window exists but was hidden (Cmd+W) — reset session state before showing drop zone.
        appState?.close()
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
        print("[AppState] showOpenPanel() called — current session: \(sessionURL?.lastPathComponent ?? "none")")
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ptx") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        panel.prompt               = "Open"
        panel.message              = "Select a Pro Tools session file"
        print("[AppState] panel.begin() called")
        panel.begin { [weak self] response in
            print("[AppState] panel completion: response=\(response.rawValue), self=\(self == nil ? "nil" : "alive")")
            guard response == .OK, let url = panel.url else {
                print("[AppState] panel cancelled or no URL")
                return
            }
            print("[AppState] panel selected: \(url.lastPathComponent)")
            self?.open(url: url)
        }
        print("[AppState] panel.begin() returned (panel now showing)")
    }

    func open(url: URL) {
        print("[AppState] open() called: \(url.lastPathComponent), cancelling existing task=\(openTask != nil)")
        openTask?.cancel()
        openTask = Task { await _open(url: url) }
    }

    private func _open(url: URL) async {
        print("[AppState] _open() start: \(url.lastPathComponent), cancelled=\(Task.isCancelled)")
        isLoading  = true
        errorText  = nil
        sessionURL = url

        // Parse binary
        var parsed: PTXSession
        do {
            print("[AppState] _open() parsing…")
            parsed = try PTXParser.parse(url: url)
            print("[AppState] _open() parse done: \(parsed.tracks.count) tracks")
        } catch {
            print("[AppState] _open() parse error: \(error)")
            errorText = error.localizedDescription
            isLoading = false
            return
        }

        guard !Task.isCancelled else { print("[AppState] _open() cancelled after parse"); isLoading = false; return }

        // Resolve audio files
        print("[AppState] _open() resolving audio files…")
        PTXParser.resolveAudioFiles(session: &parsed, sessionURL: url)
        print("[AppState] _open() resolved \(parsed.resolvedAudioFiles.count) audio files")

        // Publish initial result so UI appears immediately
        print("[AppState] _open() publishing session to UI")
        session   = parsed
        isLoading = false

        // Ensure the main window is visible — handles the case where the user closed
        // the macOS window then opened a new session via menu or Finder.
        // Exclude NSSavePanel/NSOpenPanel: they linger in NSApp.windows after dismissal
        // and makeKeyAndOrderFront would re-raise the open panel instead of the app window.
        let wins = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible)" }
        print("[AppState] _open() NSApp.windows: \(wins)")
        let appWin = NSApp.windows.first(where: { $0.isVisible && !($0 is NSSavePanel) })
                  ?? NSApp.windows.first(where: { !($0 is NSSavePanel) })
        print("[AppState] _open() makeKeyAndOrderFront on: \(appWin.map { String(describing: type(of: $0)) } ?? "nil")")
        appWin?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Augment with PTSL in background (no-op if PT not connected)
        print("[AppState] _open() awaiting PTSL…")
        await PTSLSessionInfo.shared.augment(session: &parsed)
        print("[AppState] _open() PTSL done, cancelled=\(Task.isCancelled), sessionURL=\(sessionURL?.lastPathComponent ?? "nil")")

        // Discard PTSL result if this open was superseded by close or a newer open
        guard !Task.isCancelled, sessionURL == url else {
            print("[AppState] _open() discarding PTSL result (superseded or cancelled)")
            return
        }
        session = parsed
        print("[AppState] _open() complete ✓")

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
        Group {
            if let session = appState.session, let url = appState.sessionURL {
                SessionInspectorView(
                    session:          session,
                    sessionURL:       url,
                    onOpenInProTools: { appState.openInProTools() },
                    onClose:          { appState.close() }
                )
                .id(url)   // force full view recreation (fresh @StateObject/@State) on every new session
            } else if appState.isLoading {
                ProgressView("Parsing session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                dropZone
            }
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
                Task { @MainActor in appState.open(url: url) }
            }
            return true
        }
    }
}
