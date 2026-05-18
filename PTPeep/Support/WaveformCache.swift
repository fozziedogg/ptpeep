import Foundation

// MARK: - Waveform disk cache
//
// Stores per-clip PCM peak arrays at:
//   ~/Library/Application Support/PTPeep/wavecache/<hash>_<mtime>.wc
//
// Cache key = FNV-1a hash of (audioFilePath | startSample | lengthSamples | resolution).
// The audio file's mtime is baked into the filename so stale entries are ignored
// automatically when the source file changes (old files are left on disk and cleaned
// up by the periodic trim in init).
//
// Binary format per file:
//   [Int32LE channelCount][Int32LE resolution]
//   [Float32LE × resolution] × channelCount

final class WaveformCache: @unchecked Sendable {
    static let shared = WaveformCache()

    private let cacheDir: URL?
    private let queue = DispatchQueue(label: "ptpeep.wavecache", qos: .utility)

    private init() {
        cacheDir = AppLog.appSupportDir?.appendingPathComponent("wavecache")
        if let dir = cacheDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            trimOldEntries(in: dir)
        }
    }

    // MARK: - Public API

    func get(audioURL: URL, startSample: Int64, lengthSamples: Int64,
             resolution: Int) -> [[Float]]? {
        guard let url = cacheFileURL(audioURL: audioURL, startSample: startSample,
                                     lengthSamples: lengthSamples, resolution: resolution),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return decode(data, resolution: resolution)
    }

    func set(peaks: [[Float]], audioURL: URL, startSample: Int64, lengthSamples: Int64,
             resolution: Int) {
        guard let url = cacheFileURL(audioURL: audioURL, startSample: startSample,
                                     lengthSamples: lengthSamples, resolution: resolution)
        else { return }
        let data = encode(peaks)
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    // MARK: - Cache file URL

    private func cacheFileURL(audioURL: URL, startSample: Int64, lengthSamples: Int64,
                               resolution: Int) -> URL? {
        guard let dir = cacheDir else { return nil }
        let mt   = mtime(for: audioURL)
        let key  = fnv1a("\(audioURL.path)|\(startSample)|\(lengthSamples)|\(resolution)")
        let mtMs = Int64(mt * 1000)
        return dir.appendingPathComponent("\(key)_\(mtMs).wc2")
    }

    private func mtime(for url: URL) -> TimeInterval {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap { $0.contentModificationDate }
            .map { $0.timeIntervalSince1970 } ?? 0
    }

    // MARK: - Encode / decode

    private func encode(_ peaks: [[Float]]) -> Data {
        let ch  = Int32(peaks.count)
        let res = Int32(peaks.first?.count ?? 0)
        var data = Data(capacity: 8 + Int(ch) * Int(res) * 4)
        data.appendLE(ch)
        data.appendLE(res)
        for channel in peaks {
            for v in channel { data.appendLE(v.bitPattern) }
        }
        return data
    }

    private func decode(_ data: Data, resolution: Int) -> [[Float]]? {
        guard data.count >= 8 else { return nil }
        let ch  = Int(data.loadLE(Int32.self, at: 0))
        let res = Int(data.loadLE(Int32.self, at: 4))
        guard ch > 0, res == resolution,
              data.count >= 8 + ch * res * 4 else { return nil }
        return (0..<ch).map { c in
            (0..<res).map { i in
                Float(bitPattern: data.loadLE(UInt32.self, at: 8 + (c * res + i) * 4))
            }
        }
    }

    // MARK: - FNV-1a hash (stable, no external dependencies)

    private func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Trim (keep newest 500 entries)

    private func trimOldEntries(in dir: URL) {
        queue.async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles)
            else { return }
            let wcFiles = items.filter { $0.pathExtension == "wc" }
            guard wcFiles.count > 500 else { return }
            let sorted = wcFiles.sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return d0 < d1
            }
            for url in sorted.prefix(wcFiles.count - 500) {
                try? fm.removeItem(at: url)
            }
        }
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func loadLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            self.copyBytes(to: dest, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }
}
