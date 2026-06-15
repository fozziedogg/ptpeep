import Foundation

// Dump the 0x2619/0x2623/0x2624 blocks that contain the video clip names.
// Also dump the 0x1052 and 0x104f audio playlist blocks for structural comparison.
// Goal: find the video track timeline placement (where clips sit in the session).

let baseNeedle = Array("Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole".utf8)

@main
struct DumpVideoPlaylist {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_video_playlist <file.ptx>\n", stderr); exit(1)
        }
        let url  = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw  = try! Data(contentsOf: url)
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // ── 1. 0x2619 blocks containing video clip names ──────────────────────
        print("═══ 0x2619 blocks ═══")
        for b in blocks.filter({ $0.ct == 0x2619 }) {
            let hasVideo = containsNeedle(data, in: b)
            let allHex   = (0..<min(b.size, 128)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size) hasVideo=\(hasVideo)")
            print("  \(allHex)\(b.size > 128 ? " ..." : "")")
            print()
        }

        // ── 2. 0x2623 blocks ──────────────────────────────────────────────────
        print("═══ 0x2623 blocks ═══")
        for b in blocks.filter({ $0.ct == 0x2623 }) {
            let allHex = (0..<min(b.size, 256)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size)")
            print("  \(allHex)\(b.size > 256 ? " ..." : "")")
            print()
        }

        // ── 3. 0x2624 blocks ──────────────────────────────────────────────────
        print("═══ 0x2624 blocks ═══")
        for b in blocks.filter({ $0.ct == 0x2624 }) {
            let allHex = (0..<min(b.size, 256)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size)")
            print("  \(allHex)\(b.size > 256 ? " ..." : "")")
            print()
        }

        // ── 4. First 0x1052 block (audio track playlist) for comparison ───────
        print("═══ first 0x1052 block (audio playlist, first 128 bytes) ═══")
        if let b = blocks.first(where: { $0.ct == 0x1052 }) {
            let allHex = (0..<min(b.size, 128)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size)")
            print("  \(allHex)")
        }

        // ── 5. First few 0x104f blocks (audio clip placement) for comparison ──
        print("\n═══ first 3 × 0x104f blocks (audio clip placements) ═══")
        for b in blocks.filter({ $0.ct == 0x104f }).prefix(3) {
            let allHex = (0..<min(b.size, 64)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size)  \(allHex)")
        }
    }

    static func containsNeedle(_ data: Data, in b: Block) -> Bool {
        for i in b.off ..< (b.off + b.size - baseNeedle.count) {
            if (0..<baseNeedle.count).allSatisfy({ data[i + $0] == baseNeedle[$0] }) { return true }
        }
        return false
    }

    struct Block { let ct: UInt16; let off: Int; let size: Int }

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
