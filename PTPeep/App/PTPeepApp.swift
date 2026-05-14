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

    /// Direct weak reference to the main app window, updated whenever it becomes key.
    /// More reliable than searching NSApp.windows, which can miss the window mid-transition.
    weak var mainWindow: NSWindow?
    private var windowObserver: Any?
    private var closeInterceptor: CloseInterceptorDelegate?

    init() {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let win = notification.object as? NSWindow,
                  !(win is NSSavePanel) else { return }
            self.mainWindow = win
            // Install close interceptor once per window instance so Cmd+W hides
            // rather than destroys the window (AppKit default is true close).
            if !(win.delegate is CloseInterceptorDelegate) {
                let interceptor = CloseInterceptorDelegate(
                    originalDelegate: win.delegate
                ) { [weak self] in self?.close() }
                win.delegate = interceptor
                self.closeInterceptor = interceptor
            }
        }
    }

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
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url: url)
        }
    }

    func open(url: URL) {
        print("[AppState] open() \(url.lastPathComponent)")
        openTask?.cancel()
        openTask = Task { await _open(url: url) }
    }

    private func _open(url: URL) async {
        print("[AppState] _open() start: \(url.lastPathComponent)")
        isLoading  = true
        errorText  = nil
        sessionURL = url

        // Parse binary
        var parsed: PTXSession
        do {
            parsed = try PTXParser.parse(url: url)
            print("[AppState] _open() parse done: \(parsed.tracks.count) tracks")
        } catch {
            print("[AppState] _open() parse error: \(error)")
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

        // Bring the window forward (it may have been hidden via Cmd+W / orderOut).
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Augment with PTSL in background (no-op if PT not connected)
        await PTSLSessionInfo.shared.augment(session: &parsed)
        print("[AppState] _open() PTSL done, sessionURL=\(sessionURL?.lastPathComponent ?? "nil")")

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

// MARK: - Close interceptor

/// Converts Cmd+W / close-button clicks from a true NSWindow close into orderOut
/// (hide), so the window can be brought back when the next session is opened.
/// All other delegate messages are forwarded to SwiftUI's original delegate.
private final class CloseInterceptorDelegate: NSObject, NSWindowDelegate {
    private weak var originalDelegate: NSWindowDelegate?
    private let onClose: () -> Void

    init(originalDelegate: NSWindowDelegate?, onClose: @escaping () -> Void) {
        self.originalDelegate = originalDelegate
        self.onClose = onClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()            // clear session / loading state
        sender.orderOut(nil) // hide window rather than destroy it
        return false         // tell AppKit not to close
    }

    // Forward all other NSWindowDelegate messages to SwiftUI's original delegate.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        originalDelegate?.responds(to: aSelector) == true ? originalDelegate : nil
    }
}
