import SwiftUI

/// Invokes `onClose` when the hosting NSWindow actually closes — reliable where
/// SwiftUI's `.onDisappear` is not for `Window` scenes. Shared by the detached
/// Audio Files and Video windows.
struct WindowCloseObserver: NSViewRepresentable {
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
