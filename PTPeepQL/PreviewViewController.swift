import Cocoa
import Quartz
import SwiftUI

// MARK: - Quick Look Preview Extension
//
// Installed as a QLPreviewExtension target. When a user presses Space
// on a .ptx file in Finder, macOS invokes this controller.

class PreviewViewController: NSViewController, QLPreviewingController {

    private var hostingView: NSHostingView<AnyView>?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        view.autoresizingMask = [.width, .height]
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        // Parse the session file
        var session: PTXSession
        do {
            session = try PTXParser.parse(url: url)
        } catch {
            session = PTXSession()
            session.sessionName = url.deletingPathExtension().lastPathComponent
        }

        // Load plugin index from cache (fast synchronous read — no binary scan)
        let pluginResult = PluginScanner.qlLoadIndex()

        // Render on main thread
        await MainActor.run {
            let qlView = QuickLookPreviewView(session: session, pluginResult: pluginResult)
            let hosting = NSHostingView(rootView: AnyView(qlView))
            hosting.frame = view.bounds
            hosting.autoresizingMask = [.width, .height]
            view.addSubview(hosting)
            hostingView = hosting
        }
    }

    // MARK: - Open in Pro Tools

    private func openInProTools(url: URL) {
        // Try PTSL first (opens without a dialog in PT 2025.06+)
        Task {
            // Fall back to NSWorkspace if PTSL fails
            try? await NSWorkspace.shared.open(
                [url],
                withApplicationAt: proToolsURL() ?? URL(fileURLWithPath: "/Applications/Pro Tools.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    private func proToolsURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            "/Applications/Pro Tools.app",
            "/Applications/Avid/Pro Tools.app",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { fm.fileExists(atPath: $0.path) }
    }
}
