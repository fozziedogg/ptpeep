import Foundation

// Diagnose video clip pool for Ninvingajuliat Mix 2026May3.ptx
// Expected: video track PIX has clip "Nivingajuliat - sound for Matt at 00:59:58:00"
// Actual:   showing "240313_GAYLE_A0033.MXF_07-01"
//
// Dumps:
//  1. All 0x262d blocks (video clip pool parents) and their 0x2628 children
//  2. All 0x2628 blocks NOT inside a 0x262d (to see if audio pool bleeds in)
//  3. The 0x1055 container and its 0x104f refs (clip indices + timeline positions)

struct DumpNinvingVideo {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_ninving_video <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // ── 1. All 0x262d blocks and their 0x2628 children ──
        let parentRanges262d: [(Int, Int)] = blocks
            .filter { $0.ct == 0x262d }
            .map { ($0.off, $0.off + $0.size) }
            .sorted { $0.0 < $1.0 }

        print("═══ 0x262d blocks (video clip pool parents): \(parentRanges262d.count) ═══")
        for (i, r) in parentRanges262d.enumerated() {
            print("  [\(i)] @\(r.0) len=\(r.1 - r.0)")
        }
        print()

        // Collect 0x2628 blocks that live inside a 0x262d
        func isInVideoPool(_ b: Block) -> Bool {
            var lo = 0, hi = parentRanges262d.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if parentRanges262d[mid].0 <= b.off { lo = mid + 1 } else { hi = mid }
            }
            let idx = lo - 1
            guard idx >= 0 else { return false }
            return b.off + b.size <= parentRanges262d[idx].1
        }

        print("═══ 0x2628 blocks INSIDE 0x262d (video pool entries) ═══")
        var poolIndex = 0
        for b in blocks where b.ct == 0x2628 {
            guard isInVideoPool(b) else { continue }
            let name = readName(data, at: b.off)
            print("  pool[\(poolIndex)] @\(b.off) size=\(b.size) name=\(name ?? "<nil>")")
            poolIndex += 1
        }
        print("  Total video pool entries: \(poolIndex)")
        print()

        // ── 2. All 0x2628 blocks NOT inside a 0x262d ──
        print("═══ 0x2628 blocks OUTSIDE 0x262d (audio or compound pool) — first 10 ═══")
        var audioCount = 0
        for b in blocks where b.ct == 0x2628 {
            guard !isInVideoPool(b) else { continue }
            if audioCount < 10 {
                let name = readName(data, at: b.off)
                print("  @\(b.off) size=\(b.size) name=\(name ?? "<nil>")")
            }
            audioCount += 1
        }
        print("  Total non-video 0x2628: \(audioCount)")
        print()

        // ── 3. 0x1055 container and its 0x104f refs ──
        let containers1055 = blocks.filter { $0.ct == 0x1055 }.sorted { $0.off < $1.off }
        print("═══ 0x1055 blocks (video playlist containers): \(containers1055.count) ═══")
        for c in containers1055 {
            print("  @\(c.off) size=\(c.size) range=[\(c.off)..\(c.off + c.size)]")
            // Find 0x104f refs inside this container
            let refs = blocks.filter {
                $0.ct == 0x104f && $0.off >= c.off && $0.off + $0.size <= c.off + c.size
            }.sorted { $0.off < $1.off }
            print("  0x104f refs inside: \(refs.count)")
            for r in refs {
                guard r.off + 12 <= data.count else { continue }
                let b0  = data[r.off + 0]
                let b1  = data[r.off + 1]
                let b2  = data[r.off + 2]
                let b3  = data[r.off + 3]
                let clipIdx = Int(b3)
                let framePos = u32(data, at: r.off + 7)
                // Also show raw first 16 bytes for layout debugging
                let raw16 = (0..<min(16, r.size)).map { String(format: "%02x", data[r.off + $0]) }.joined(separator: " ")
                print(String(format: "    ref@%d size=%d b[0-3]=%02x %02x %02x %02x  clipIdx=%d  framePos=%d  raw=%@",
                             r.off, r.size, b0, b1, b2, b3, clipIdx, framePos, raw16))
            }
        }
        print()

        // ── 4. Search for "Nivingajuliat" string in all blocks ──
        let needle = Array("Nivingajuliat".utf8)
        print("═══ Searching for \"Nivingajuliat\" in data ═══")
        for i in 0 ..< (data.count - needle.count) {
            guard (0..<needle.count).allSatisfy({ data[i + $0] == needle[$0] }) else { continue }
            var end = i; while end < data.count && data[end] >= 0x20 { end += 1 }
            let s = String(bytes: data[i..<end], encoding: .utf8) ?? "???"
            let inBlocks = blocks.filter { $0.off <= i && i < $0.off + $0.size }
                .map { String(format: "ct=0x%04x@%d", $0.ct, $0.off) }.joined(separator: ", ")
            print("  @\(i) \"\(s)\"  in: \(inBlocks)")
        }
        print()

        // ── 5. Search for "240313_GAYLE" string ──
        let needle2 = Array("240313_GAYLE".utf8)
        print("═══ Searching for \"240313_GAYLE\" in data ═══")
        for i in 0 ..< (data.count - needle2.count) {
            guard (0..<needle2.count).allSatisfy({ data[i + $0] == needle2[$0] }) else { continue }
            var end = i; while end < data.count && data[end] >= 0x20 { end += 1 }
            let s = String(bytes: data[i..<end], encoding: .utf8) ?? "???"
            let inBlocks = blocks.filter { $0.off <= i && i < $0.off + $0.size }
                .map { String(format: "ct=0x%04x@%d", $0.ct, $0.off) }.joined(separator: ", ")
            print("  @\(i) \"\(s)\"  in: \(inBlocks)")
        }
    }

    static func readName(_ data: Data, at pos: Int) -> String? {
        guard pos + 4 <= data.count else { return nil }
        let nl = Int(UInt32(data[pos]) | UInt32(data[pos+1]) << 8 | UInt32(data[pos+2]) << 16 | UInt32(data[pos+3]) << 24)
        guard nl >= 1, nl <= 512, pos + 4 + nl <= data.count else { return nil }
        return String(bytes: data[pos+4 ..< pos+4+nl], encoding: .utf8)
    }

    static func u32(_ data: Data, at i: Int) -> UInt32 {
        guard i + 4 <= data.count else { return 0 }
        return UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
    }

    static func scanBlocks(_ data: Data) -> [Block] {
        var blocks = [Block]()
        var i = 0x1f
        while i + 9 <= data.count {
            guard data[i] == 0x5a else { i += 1; continue }
            let size = Int(UInt32(data[i+3]) | UInt32(data[i+4]) << 8 | UInt32(data[i+5]) << 16 | UInt32(data[i+6]) << 24)
            let ct   = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
            guard size > 0, size < 50_000_000, i + 9 + size <= data.count else { i += 1; continue }
            blocks.append(Block(ct: ct, off: i + 9, size: size))
            i += 1
        }
        return blocks
    }

    static func xorDecode(_ raw: Data) -> Data? {
        guard raw.count > 0x14, raw[0x12] == 0x05 else { return nil }
        let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
        for i: UInt16 in 0...255 { if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break } }
        var t = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
        var d = raw; for i in 0..<raw.count { d[i] = raw[i] ^ t[(i >> 12) & 0xff] }
        return d
    }
}
DumpNinvingVideo.run()
