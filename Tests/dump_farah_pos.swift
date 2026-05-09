import Foundation

// Find all clips with "Farah" in name, look up their 0x104f placement pos values.
// Also convert pos=172876704 to TC using different sample rates.

func run() {
    guard CommandLine.arguments.count > 1 else { print("Usage: dump_farah_pos <file.ptx>"); exit(1) }
    let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    var t = [UInt8](repeating: 0, count: 256)
    let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
    for i: UInt16 in 0...255 { if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break } }
    for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var data = raw; for i in 0..<raw.count { data[i] = raw[i] ^ t[(i >> 12) & 0xff] }

    var blocks = [(ct: UInt16, off: Int, size: Int)]()
    var i = 0x1f
    while i + 9 <= data.count {
        guard data[i] == 0x5a else { i += 1; continue }
        let sz = Int(UInt32(data[i+3]) | UInt32(data[i+4]) << 8 | UInt32(data[i+5]) << 16 | UInt32(data[i+6]) << 24)
        let ct = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
        guard sz > 0, sz < 50_000_000, i + 9 + sz <= data.count else { i += 1; continue }
        blocks.append((ct, i + 9, sz))
        i += 1
    }

    func u16le(_ off: Int) -> Int { Int(data[off]) | Int(data[off+1]) << 8 }
    func u32le(_ off: Int) -> Int64 { Int64(data[off]) | Int64(data[off+1]) << 8 | Int64(data[off+2]) << 16 | Int64(data[off+3]) << 24 }
    func hex(_ off: Int, _ n: Int) -> String {
        (0..<min(n, data.count - off)).map { String(format: "%02x", data[off + $0]) }.joined(separator: " ")
    }

    // Build clip pool: index → name
    let clipParentRanges: [(Int, Int)] = blocks
        .filter { $0.ct == 0x2629 }
        .map { ($0.off, $0.off + $0.size) }
        .sorted { $0.0 < $1.0 }
    func isInClipPool(_ block: (ct: UInt16, off: Int, size: Int)) -> Bool {
        var lo = 0, hi = clipParentRanges.count
        while lo < hi { let mid = (lo + hi) / 2; if clipParentRanges[mid].0 <= block.off { lo = mid + 1 } else { hi = mid } }
        let idx = lo - 1
        guard idx >= 0 else { return false }
        return block.off + block.size <= clipParentRanges[idx].1
    }

    var clipPool = [(idx: Int, name: String)]()
    var clipIdx = 0
    for block in blocks where block.ct == 0x2628 {
        guard isInClipPool(block) else { continue }
        let p = block.off
        let nl = Int(u32le(p))
        if nl >= 1, nl <= 512, p + 4 + nl <= data.count,
           let name = String(bytes: data[(p+4)..<(p+4+nl)], encoding: .utf8) {
            clipPool.append((clipIdx, name))
        }
        clipIdx += 1
    }

    // Find Farah clips
    let farahClips = clipPool.filter { $0.name.lowercased().contains("farah") }
    print("=== Farah clips in pool (\(farahClips.count)) ===")
    for c in farahClips { print("  [\(c.idx)] \(c.name)") }
    let farahIdxSet = Set(farahClips.map { $0.idx })

    // Find 0x104f container
    guard let container1054 = blocks.filter({ $0.ct == 0x1054 }).sorted(by: { $0.off < $1.off }).first(where: { b in
        blocks.contains { $0.ct == 0x1052 && $0.off >= b.off && $0.off + $0.size <= b.off + b.size }
    }) else { print("No 0x1054 container"); return }
    let cStart = container1054.off, cEnd = container1054.off + container1054.size

    // Build track name lookup
    let sections1052 = blocks.filter { $0.ct == 0x1052 && $0.off >= cStart && $0.off + $0.size <= cEnd }.sorted { $0.off < $1.off }
    var sectionNames: [(name: String, start: Int, end: Int)] = []
    for s in sections1052 {
        let p = s.off; let nl = Int(u32le(p))
        guard nl >= 1, nl <= 256, p + 4 + nl <= data.count else { continue }
        if let name = String(bytes: data[(p+4)..<(p+4+nl)], encoding: .utf8) {
            sectionNames.append((name, s.off, s.off + s.size))
        }
    }
    func findSection(_ off: Int) -> String {
        sectionNames.filter { $0.start <= off && off < $0.end }.last?.name ?? "<unknown>"
    }

    // Find 0x104f placement blocks for Farah clips
    let refs104f = blocks.filter { $0.ct == 0x104f && $0.size >= 16 && $0.off >= cStart && $0.off + $0.size <= cEnd }.sorted { $0.off < $1.off }

    print("\n=== 0x104f placements for Farah clips ===")
    var posValues = Set<Int64>()
    for r in refs104f {
        let ci = u16le(r.off + 2)
        guard farahIdxSet.contains(ci) else { continue }
        let pos = u32le(r.off + 7)
        posValues.insert(pos)
        let track = findSection(r.off)
        print(String(format: "  clipIdx=%d pos=%lld (0x%llx) track='%@' bytes: %@",
                     ci, pos, pos, track, hex(r.off, min(r.size, 24))))
    }

    // TC conversion for each unique pos value
    // Try different sample rates and TC offsets
    print("\n=== TC conversion for observed pos values ===")
    let sampleRates: [(Double, String)] = [(48000, "48k"), (44100, "44.1k"), (96000, "96k")]
    let fpsList: [(Double, String)] = [(24, "24fps"), (23.976, "23.976fps"), (25, "25fps"), (29.97, "29.97fps"), (30, "30fps")]

    for pos in posValues.sorted() {
        print("\npos=\(pos) (0x\(String(pos, radix:16))):")
        for (sr, srName) in sampleRates {
            let secs = Double(pos) / sr
            print("  \(srName): \(String(format: "%.4f", secs))s")
            for (fps, fpsName) in fpsList {
                let totalFrames = Int(secs * fps)
                let h = totalFrames / Int(fps * 3600)
                let m = (totalFrames % Int(fps * 3600)) / Int(fps * 60)
                let s = (totalFrames % Int(fps * 60)) / Int(fps)
                let f = totalFrames % Int(fps)
                print(String(format: "    %@ → %02d:%02d:%02d:%02d", fpsName, h, m, s, f))
            }
        }
    }

    // Also dump the "ghost" pos for comparison
    let ghostPos: Int64 = 172_876_704
    if !posValues.contains(ghostPos) {
        print("\n=== Previously identified ghostPos=\(ghostPos) (0x\(String(ghostPos, radix:16))) for comparison ===")
        for (sr, srName) in sampleRates {
            let secs = Double(ghostPos) / sr
            print("  \(srName): \(String(format: "%.4f", secs))s")
            for (fps, fpsName) in fpsList {
                let totalFrames = Int(secs * fps)
                let h = totalFrames / Int(fps * 3600)
                let m = (totalFrames % Int(fps * 3600)) / Int(fps * 60)
                let s = (totalFrames % Int(fps * 60)) / Int(fps)
                let f = totalFrames % Int(fps)
                print(String(format: "    %@ → %02d:%02d:%02d:%02d", fpsName, h, m, s, f))
            }
        }
    }
}
run()
