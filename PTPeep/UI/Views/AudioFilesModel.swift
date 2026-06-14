import Foundation

/// Per-session state for the Audio Files pane, shared between the inline tab in
/// `SessionInspectorView` and the detached floating window so both stay live.
/// Owned by `AppState` (keyed by tab id). Profiles/columns live in @AppStorage
/// (already global), so they are NOT held here.
@MainActor
final class AudioFilesModel: ObservableObject {
    let tabID: UUID
    let audioFileNames: [String]
    let sampleRate: Double
    let frameRate: Double

    @Published var resolvedLookup: [String: ResolvedAudioFile] = [:]
    @Published var bwfCache: [String: BWFMetadata] = [:]
    @Published var isLoading: Bool = false
    @Published var highlightedFiles: Set<String> = []
    /// True while the pane is popped out into the floating window (the inline
    /// tab hides itself).
    @Published var isDetached: Bool = false

    init(tabID: UUID, session: PTXSession) {
        self.tabID = tabID
        self.audioFileNames = session.audioFileNames
        self.sampleRate = Double(session.sampleRate) ?? 48000
        self.frameRate = session.frameRate
    }

    /// Refresh the resolved-file lookup (file resolution is async) and kick off
    /// BWF parsing if it hasn't run yet.
    func updateResolved(_ files: [ResolvedAudioFile]) {
        resolvedLookup = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        startParse(resolvedFiles: files)
    }

    /// Background-parse BWF metadata for every resolved file, once.
    func startParse(resolvedFiles: [ResolvedAudioFile]) {
        let files = resolvedFiles.filter { $0.url != nil }
        guard !files.isEmpty, bwfCache.isEmpty else {
            AppLog.shared.log("[BWF] startParse skipped: \(files.count) resolved, cache has \(bwfCache.count) entries")
            return
        }
        AppLog.shared.log("[BWF] Starting parse of \(files.count) resolved audio files")
        isLoading = true
        let audioNames = audioFileNames
        Task.detached(priority: .background) {
            var cache: [String: BWFMetadata] = [:]
            let batchSize = 50
            for (i, file) in files.enumerated() {
                if let url = file.url, let meta = BWFParser.parse(url: url) {
                    cache[file.name] = meta
                }
                if i % batchSize == batchSize - 1 {
                    await Task.yield()
                }
            }
            AppLog.shared.log("[BWF] Parse complete: \(cache.count)/\(files.count) files had BWF metadata")
            await MainActor.run {
                self.bwfCache = cache
                self.isLoading = false
                let afNames = audioNames.prefix(3).map { "'\($0)'" }.joined(separator: ", ")
                let cacheKeys = cache.keys.prefix(3).map { "'\($0)'" }.joined(separator: ", ")
                AppLog.shared.log("[BWF] First audioFileNames: \(afNames)")
                AppLog.shared.log("[BWF] First cache keys: \(cacheKeys)")
            }
        }
    }
}
