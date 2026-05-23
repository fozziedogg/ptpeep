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
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Session…") { appState.showOpenPanel() }
                    .keyboardShortcut("o")

                Menu("Open Recent") {
                    ForEach(appState.recentURLs, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            appState.open(url: url)
                        }
                    }
                    if !appState.recentURLs.isEmpty {
                        Divider()
                        Button("Clear Menu") { appState.clearRecents() }
                    }
                }
                .disabled(appState.recentURLs.isEmpty)

                Divider()

                Button("Close Tab") {
                    if let id = appState.selectedTabID { appState.closeTab(id: id) }
                }
                .keyboardShortcut("w")
                .disabled(appState.tabs.isEmpty)

                Button("Close All Tabs") { appState.closeAllTabs() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(appState.tabs.isEmpty)

                Divider()

                Button("Select Previous Tab") { appState.selectPreviousTab() }
                    .keyboardShortcut("[")
                    .disabled(appState.tabs.count < 2)

                Button("Select Next Tab") { appState.selectNextTab() }
                    .keyboardShortcut("]")
                    .disabled(appState.tabs.count < 2)
            }
        }
    }
}

// MARK: - Peeping loader

private struct PeepingView: View {
    @State private var isUp = false
    @State private var dotPhase = 0
    private let dotTimer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                // Squish on land, stretch on rise — spring anchored at bottom
                .scaleEffect(
                    CGSize(width: isUp ? 1.0 : 1.08, height: isUp ? 1.0 : 0.92),
                    anchor: .bottom
                )
                .offset(y: isUp ? -14 : 6)
                // Shadow grows as icon rises (further from "ground")
                .shadow(
                    color: .black.opacity(0.28),
                    radius: isUp ? 14 : 3,
                    x: 0, y: isUp ? 10 : 2
                )
                .animation(
                    .interpolatingSpring(stiffness: 85, damping: 7)
                        .repeatForever(autoreverses: true),
                    value: isUp
                )

            Text("Peeping\([".", "..", "..."][dotPhase])")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .onAppear { isUp = true }
        .onReceive(dotTimer) { _ in dotPhase = (dotPhase + 1) % 3 }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @AppStorage("colorMode")            private var colorMode:   ColorMode = .dark
    @AppStorage("audioOutputDeviceUID") private var deviceUID:   String    = ""

    @State private var outputDevices: [AudioOutputDevice] = []

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $colorMode) {
                    Text("Light").tag(ColorMode.light)
                    Text("Dark").tag(ColorMode.dark)
                    Text("GRM (color blind)").tag(ColorMode.grm)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Audio") {
                Picker("Output Device", selection: $deviceUID) {
                    Text("System Default").tag("")
                    if !outputDevices.isEmpty { Divider() }
                    ForEach(outputDevices) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: deviceUID) { uid in
                    // Notify any active AudioPlayer via UserDefaults observation.
                    // The player re-applies the preference on next play().
                    UserDefaults.standard.set(uid, forKey: "audioOutputDeviceUID")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onAppear { outputDevices = AudioDeviceManager.outputDevices() }
    }
}

// MARK: - Tab state

struct TabState: Identifiable {
    let id: UUID
    var sessionURL:       URL?
    var session:          PTXSession?
    var isLoading:        Bool
    var isResolvingFiles: Bool = false
    var errorText:        String?

    var displayName: String {
        sessionURL?.deletingPathExtension().lastPathComponent ?? "New Session"
    }

    init(sessionURL: URL? = nil, isLoading: Bool = false) {
        self.id         = UUID()
        self.sessionURL = sessionURL
        self.isLoading  = isLoading
    }
}

// MARK: - AppDelegate for Finder file-open events

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI sets its own autosave name so AppKit's frame-autosave mechanism
        // is unavailable to us. Instead we manually save/restore via our own key.
        // The restore must happen after SwiftUI's WindowGroup finishes positioning
        // the window (next run-loop cycle).
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { !($0 is NSSavePanel) }) else { return }
            if let saved = UserDefaults.standard.string(forKey: "ptpeepWindowFrame") {
                let rect = NSRectFromString(saved)
                if rect != .zero { win.setFrame(rect, display: true) }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ptx" }) else { return }
        bringWindowForward(application)
        appState?.open(url: url)
    }

    // Clicking the Dock icon brings the window back with all tabs intact.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        if app.windows.isEmpty { return false }
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
    @Published var tabs:          [TabState] = []
    @Published var selectedTabID: UUID?

    /// Direct weak reference to the main app window, updated whenever it becomes key.
    weak var mainWindow: NSWindow?
    private var windowObserver:  Any?
    private var closeInterceptor: CloseInterceptorDelegate?
    private var openTasks:        [UUID: Task<Void, Never>] = [:]
    @Published var recentURLs: [URL] = []
    private static let recentsKey = "recentSessionURLs"
    private static let maxRecents = 10

    var selectedTab: TabState? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    // MARK: Recents

    func addRecent(_ url: URL) {
        recentURLs.removeAll { $0 == url }
        recentURLs.insert(url, at: 0)
        if recentURLs.count > Self.maxRecents { recentURLs = Array(recentURLs.prefix(Self.maxRecents)) }
        UserDefaults.standard.set(recentURLs.map(\.absoluteString), forKey: Self.recentsKey)
    }

    func clearRecents() {
        recentURLs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    // MARK: Init

    init() {
        let fm = FileManager.default
        recentURLs = (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [])
            .compactMap { URL(string: $0) }
            .filter { fm.fileExists(atPath: $0.path) }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let win = notification.object as? NSWindow,
                  !(win is NSSavePanel) else { return }
            MainActor.assumeIsolated {
                self.mainWindow = win
                if win.frameAutosaveName.isEmpty {
                    win.setFrameAutosaveName("PTPeepMainWindow")
                }
                if !(win.delegate is CloseInterceptorDelegate) {
                    let interceptor = CloseInterceptorDelegate(originalDelegate: win.delegate)
                    win.delegate = interceptor
                    self.closeInterceptor = interceptor
                }
            }
        }
    }

    // MARK: Tab management

    private func updateTab(id: UUID, _ update: (inout TabState) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        update(&tabs[idx])
    }

    func updateWindowTitle() {
        if let tab = selectedTab {
            mainWindow?.title = "PTpeep — \(tab.displayName)"
        } else {
            mainWindow?.title = "PTpeep"
        }
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        openTasks[id]?.cancel()
        openTasks[id] = nil
        tabs.remove(at: idx)
        if tabs.isEmpty {
            selectedTabID = nil
        } else {
            selectedTabID = tabs[min(idx, tabs.count - 1)].id
        }
        updateWindowTitle()
    }

    func closeAllTabs() {
        for id in tabs.map(\.id) { openTasks[id]?.cancel() }
        openTasks.removeAll()
        tabs.removeAll()
        selectedTabID = nil
        updateWindowTitle()
    }

    func selectNextTab() {
        guard tabs.count > 1,
              let id = selectedTabID,
              let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        selectedTabID = tabs[(idx + 1) % tabs.count].id
        updateWindowTitle()
    }

    func selectPreviousTab() {
        guard tabs.count > 1,
              let id = selectedTabID,
              let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        selectedTabID = tabs[(idx - 1 + tabs.count) % tabs.count].id
        updateWindowTitle()
    }

    // MARK: Open

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
        AppLog.shared.log("[AppState] open() \(url.lastPathComponent)")
        let tab = TabState(sessionURL: url, isLoading: true)
        tabs.append(tab)
        selectedTabID = tab.id
        updateWindowTitle()
        openTasks[tab.id] = Task { await _open(tabID: tab.id, url: url) }
    }

    func rescan(tabID: UUID, url: URL) {
        AppLog.shared.log("[AppState] rescan() \(url.lastPathComponent)")
        openTasks[tabID]?.cancel()
        updateTab(id: tabID) { $0.isLoading = true; $0.errorText = nil }
        openTasks[tabID] = Task { await _open(tabID: tabID, url: url) }
    }

    private func _open(tabID: UUID, url: URL) async {
        AppLog.shared.log("[AppState] _open() start: \(url.lastPathComponent)")

        // Parse binary
        var parsed: PTXSession
        do {
            parsed = try PTXParser.parse(url: url)
            AppLog.shared.log("[AppState] _open() parse done: \(parsed.tracks.count) tracks")
        } catch {
            AppLog.shared.log("[AppState] _open() parse error: \(error)")
            updateTab(id: tabID) { $0.isLoading = false; $0.errorText = error.localizedDescription }
            return
        }

        guard !Task.isCancelled else {
            updateTab(id: tabID) { $0.isLoading = false }
            return
        }

        // Publish immediately so the UI appears without waiting for file resolution
        updateTab(id: tabID) { $0.session = parsed; $0.isLoading = false; $0.isResolvingFiles = true }
        addRecent(url)
        updateWindowTitle()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        PTXParser.writeClipLog(session: parsed, sessionURL: url)

        // Resolve audio files off the main thread — can be slow for large sessions
        let resolveURL = url
        let resolveTabID = tabID
        Task.detached(priority: .utility) { [weak self] in
            var copy = parsed
            PTXParser.resolveAudioFiles(session: &copy, sessionURL: resolveURL)
            let resolved = copy.resolvedAudioFiles
            await MainActor.run { [weak self] in
                self?.updateTab(id: resolveTabID) {
                    $0.session?.resolvedAudioFiles = resolved
                    $0.isResolvingFiles = false
                }
            }
        }
        AppLog.shared.log("[AppState] _open() complete ✓")
    }

    func openInProTools(url: URL) {
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
    @AppStorage("colorMode") private var colorMode: ColorMode = .dark

    var body: some View {
        VStack(spacing: 0) {
            if !appState.tabs.isEmpty {
                TabBarView()
                Divider()
            }
            ZStack {
                if appState.tabs.isEmpty {
                    dropZone
                } else if let tab = appState.selectedTab {
                    tabContent(tab)
                        .id(tab.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(colorMode.colorScheme)
        .onChange(of: appState.selectedTabID) { _ in appState.updateWindowTitle() }
        // Accept drops anywhere in the window to open a new tab.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "ptx" else { return }
                Task { @MainActor in appState.open(url: url) }
            }
            return true
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TabState) -> some View {
        if let session = tab.session, let url = tab.sessionURL {
            SessionInspectorView(
                session:             session,
                sessionURL:          url,
                isResolvingFiles:    tab.isResolvingFiles,
                onOpenInProTools:    { appState.openInProTools(url: url) },
                onRescan:            { appState.rescan(tabID: tab.id, url: url) },
                onClose:             { appState.closeTab(id: tab.id) }
            )
        } else if tab.isLoading {
            PeepingView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = tab.errorText {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Close Tab") { appState.closeTab(id: tab.id) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button("Choose Session…") { appState.showOpenPanel() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(appState.tabs) { tab in
                        TabItemView(tab: tab)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 4)

            Button {
                appState.showOpenPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open Session…")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TabItemView: View {
    @EnvironmentObject var appState: AppState
    let tab: TabState
    @State private var isHovered = false

    private var isSelected: Bool { appState.selectedTabID == tab.id }

    var body: some View {
        HStack(spacing: 3) {
            if tab.isLoading {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 10, height: 10)
            }

            Text(tab.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)

            Button {
                appState.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 13, height: 13)
                    .background(
                        Circle()
                            .fill(Color(nsColor: .labelColor).opacity(isHovered ? 0.1 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovered ? 1 : 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected
                    ? Color(nsColor: .labelColor).opacity(0.1)
                    : Color(nsColor: .labelColor).opacity(isHovered ? 0.05 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected
                    ? Color(nsColor: .separatorColor).opacity(0.6)
                    : Color.clear,
                    lineWidth: 0.5)
        )
        .onTapGesture { appState.selectedTabID = tab.id; appState.updateWindowTitle() }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

// MARK: - Close interceptor

/// Intercepts the window red-button / Window > Close, hiding the window
/// rather than destroying it. Cmd+W is handled by SwiftUI commands (close tab).
/// All other delegate messages are forwarded to SwiftUI's original delegate.
private final class CloseInterceptorDelegate: NSObject, NSWindowDelegate {
    private weak var originalDelegate: NSWindowDelegate?

    init(originalDelegate: NSWindowDelegate?) {
        self.originalDelegate = originalDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        if let win = notification.object as? NSWindow {
            UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: "ptpeepWindowFrame")
        }
        originalDelegate?.windowDidMove?(notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let win = notification.object as? NSWindow {
            UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: "ptpeepWindowFrame")
        }
        originalDelegate?.windowDidEndLiveResize?(notification)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        originalDelegate?.responds(to: aSelector) == true ? originalDelegate : nil
    }
}
