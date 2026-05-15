import Foundation
import SwiftUI

// MARK: - Plugin cache (persisted to Application Support)

private struct PluginCache: Codable {
    struct Entry: Codable, Equatable {
        var path:     String
        var modified: Double
    }
    var signature: [Entry]
    var index:     InstalledPluginIndex
}

// MARK: - Installed plugin index

/// Indexes installed .aaxplugin bundles for matching against PTX plugin entries.
/// Match order:
///   1. PTX second string vs reverse-DNS IDs from the bundle binary (covers legacy
///      Digidesign IDs and modern Avid IDs even when plist uses a different ID)
///   2. PTX second string variant name (format suffix stripped) vs CFBundleName
///      (iZotope-style: "RX 9 Monitor Mono" → strip → "RX 9 Monitor")
///   3. PTX display name vs CFBundleName
struct InstalledPluginIndex: Codable {
    var bundleIds:   Set<String> = []
    var bundleNames: Set<String> = []

    mutating func add(bundleURL: URL) {
        let contents = bundleURL.appendingPathComponent("Contents")

        // Plist: CFBundleIdentifier + CFBundleName
        if let dict = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) {
            if let bid = dict["CFBundleIdentifier"] as? String { bundleIds.insert(bid.lowercased()) }
            if let bn  = dict["CFBundleName"]       as? String { bundleNames.insert(bn.lowercased()) }
        }

        // Binary scan: first 4MB of the MacOS executable for reverse-DNS strings.
        // AAX registration IDs are compiled in and match what PT stores in the session,
        // even when the plist uses a newer/different ID (e.g. EQIII vs eq3.7band).
        let macosDir = contents.appendingPathComponent("MacOS")
        if let exes = try? FileManager.default.contentsOfDirectory(at: macosDir,
                                                                    includingPropertiesForKeys: nil),
           let exe  = exes.first,
           let fh   = try? FileHandle(forReadingFrom: exe) {
            let data = fh.readData(ofLength: 4 * 1024 * 1024)
            try? fh.close()
            extractReverseDNSStrings(from: data)
        }
    }

    private mutating func extractReverseDNSStrings(from data: Data) {
        let dot = UInt8(ascii: ".")
        var i = 0
        while i < data.count - 10 {
            let b = data[i]
            // Must start with com. / net. / org.
            let isMatch = (b == UInt8(ascii: "c") && i+3 < data.count &&
                           data[i+1] == UInt8(ascii: "o") && data[i+2] == UInt8(ascii: "m") && data[i+3] == dot) ||
                          (b == UInt8(ascii: "n") && i+3 < data.count &&
                           data[i+1] == UInt8(ascii: "e") && data[i+2] == UInt8(ascii: "t") && data[i+3] == dot) ||
                          (b == UInt8(ascii: "o") && i+3 < data.count &&
                           data[i+1] == UInt8(ascii: "r") && data[i+2] == UInt8(ascii: "g") && data[i+3] == dot)
            guard isMatch else { i += 1; continue }
            var end = i + 4
            while end < data.count && end - i < 128 {
                let c = data[end]
                if c == 0 || c == 10 || c == 13 || c == 32 || c < 32 || c > 126 { break }
                end += 1
            }
            if end - i >= 10, let s = String(bytes: data[i..<end], encoding: .utf8) {
                bundleIds.insert(s.lowercased())
            }
            i = end + 1
        }
    }

    func contains(_ displayName: String, secondString: String?) -> Bool {
        let stripped = stripFormatSuffix(displayName).lowercased()
        if let s = secondString, s.contains("."), bundleIds.contains(s.lowercased()) { return true }
        if let s = secondString, bundleNames.contains(stripFormatSuffix(s).lowercased()) { return true }
        return bundleNames.contains(stripped)
    }

    private func stripFormatSuffix(_ s: String) -> String {
        var result = s
        if let paren = result.lastIndex(of: "("), result.last == ")" {
            let before = result[result.startIndex ..< paren]
            if before.last == " " { result = String(before.dropLast()) }
        }
        for suffix in [" Mono", " Stereo", " 5.1", " 7.1", " LCR", " Quad"] {
            if result.hasSuffix(suffix) { result = String(result.dropLast(suffix.count)); break }
        }
        return result
    }
}

// MARK: - Plugin scanner singleton

@MainActor
final class PluginScanner: ObservableObject {
    static let shared = PluginScanner()
    private init() {}

    @Published private(set) var isScanning    = false
    @Published private(set) var scanCompleted = false
    @Published private(set) var statusMessage = ""
    private(set) var index: InstalledPluginIndex? = nil

    private nonisolated static let aaxDirs: [URL] = [
        URL(fileURLWithPath: "/Library/Application Support/Avid/Audio/Plug-Ins"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Avid/Audio/Plug-Ins")
    ]

    private nonisolated static var cacheURL: URL? {
        AppLog.appSupportDir?.appendingPathComponent("plugin-cache.json")
    }

    // MARK: Startup check (fast — metadata only, no binary reads)

    /// Called at app start. Builds a directory signature and compares to the cached one.
    /// If valid, loads the index from cache immediately (no scan needed).
    /// If stale or missing, does nothing — UI will show the Scan button.
    func startupCheck() {
        guard !isScanning, !scanCompleted else { return }
        isScanning    = true
        statusMessage = "Checking plug-in index…"
        Task.detached(priority: .userInitiated) {
            let sig = Self.buildSignature()
            if let url  = Self.cacheURL,
               let data = try? Data(contentsOf: url),
               let cache = try? JSONDecoder().decode(PluginCache.self, from: data),
               cache.signature == sig {
                AppLog.shared.log("[PluginScan] Cache valid — \(cache.index.bundleIds.count) IDs, \(sig.count) bundles.")
                await MainActor.run {
                    self.index         = cache.index
                    self.isScanning    = false
                    self.scanCompleted = true
                    self.statusMessage = ""
                }
            } else {
                AppLog.shared.log("[PluginScan] Cache stale or missing — manual scan required.")
                await MainActor.run {
                    self.isScanning    = false
                    self.statusMessage = ""
                }
            }
        }
    }

    // MARK: Full scan (slow — reads binary of each bundle)

    func scan() {
        guard !isScanning else { return }
        isScanning    = true
        statusMessage = "Scanning plug-in folder…"
        Task.detached(priority: .userInitiated) {
            AppLog.shared.log("[PluginScan] Full scan started.")
            var idx   = InstalledPluginIndex()
            var sig   = [PluginCache.Entry]()
            let fm    = FileManager.default
            var count = 0
            for dir in Self.aaxDirs {
                AppLog.shared.log("[PluginScan] Scanning \(dir.path)")
                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { AppLog.shared.log("[PluginScan] Cannot enumerate \(dir.path)"); continue }

                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "aaxplugin" else { continue }
                    count += 1
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                        .flatMap { $0.contentModificationDate }?.timeIntervalSince1970 ?? 0
                    sig.append(.init(path: url.path, modified: modified))

                    AppLog.shared.log("[PluginScan] [\(count)] \(url.lastPathComponent)")
                    let t = Date()
                    idx.add(bundleURL: url)
                    let ms = Int(Date().timeIntervalSince(t) * 1000)
                    if ms > 50 { AppLog.shared.log("[PluginScan]   → \(ms)ms") }

                    enumerator.skipDescendants()
                    let n = count
                    await MainActor.run { self.statusMessage = "Scanning… (\(n) found)" }
                }
            }

            sig.sort { $0.path < $1.path }
            AppLog.shared.log("[PluginScan] Done. \(count) bundles, \(idx.bundleIds.count) IDs indexed.")

            // Persist cache
            if let url = Self.cacheURL,
               let data = try? JSONEncoder().encode(PluginCache(signature: sig, index: idx)) {
                let dir = url.deletingLastPathComponent()
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: url)
                AppLog.shared.log("[PluginScan] Cache saved → \(url.path)")
            }

            await MainActor.run {
                self.index         = idx
                self.isScanning    = false
                self.scanCompleted = true
                self.statusMessage = ""
            }
        }
    }

    // MARK: Signature (metadata-only walk, ~50ms for 200 plugins)

    private nonisolated static func buildSignature() -> [PluginCache.Entry] {
        var entries = [PluginCache.Entry]()
        let fm = FileManager.default
        for dir in aaxDirs {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "aaxplugin" {
                    let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                        .flatMap { $0.contentModificationDate }?.timeIntervalSince1970 ?? 0
                    entries.append(.init(path: url.path, modified: mod))
                    enumerator.skipDescendants()
                }
            }
        }
        return entries.sorted { $0.path < $1.path }
    }
}
