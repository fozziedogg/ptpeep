import Foundation

// MARK: - App-wide file logger
//
// Appends timestamped lines to:
//   ~/Library/Application Support/PTPeep/ptpeep.log
//
// All writes go through a serial background queue so callers never block.
// The formatter is only accessed on that queue, avoiding thread-safety issues.

final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    /// URL for external access (e.g. "Reveal Log" button).
    static var logFileURL: URL? { appSupportDir?.appendingPathComponent("ptpeep.log") }

    static var appSupportDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PTPeep")
    }

    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "ptpeep.log", qos: .background)
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        queue.async { self.openFile() }
    }

    private func openFile() {
        guard let url = AppLog.logFileURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        writeRaw("--- App launched \(formatter.string(from: Date())) ---\n")
    }

    func log(_ message: String) {
        let now = Date()
        print(message)
        queue.async { [weak self] in
            guard let self else { return }
            self.writeRaw("[\(self.formatter.string(from: now))] \(message)\n")
        }
    }

    private func writeRaw(_ s: String) {
        handle?.write(s.data(using: .utf8) ?? Data())
    }
}
