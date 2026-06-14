import Foundation

// Dump 0x262d (video clip entries) full content side by side with 0x2629 (audio clip entries)
// Goal: find start/length sample offsets in the video clip block structure.

let videoClipNames = [
    "Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole_81733583_00122907_00172823_en_2",
    "Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole_81733583_00122907_00172823_en_2-22",
    "Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole_81733583_00122907_00172823_en_2-16",
    "Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole_81733583_00122907_00172823_en_2-29",
]

@main
struct DumpVideoBlocks {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_video_blocks <file.ptx>\n", stderr); exit(1)
        }
        let url  = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw  = try! Data(contentsOf: url)
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // ── 1. All 0x262d blocks (video clip entries) ──────────────────────────
        print("═══ 0x262d blocks (video clip entries) ═══")
        for b in blocks.filter({ $0.ct == 0x262d }) {
            // try to find a clip name in this block
            var clipName = "?"
            for name in videoClipNames {
                let needle = Array(name.utf8)
                for i in b.off ..< (b.off + b.size - needle.count) {
                    if (0..<needle.count).allSatisfy({ data[i + $0] == needle[$0] }) {
                        clipName = name
                        break
                    }
                }
                if clipName != "?" { break }
            }
            let allHex = (0..<b.size).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size) [\(clipName.suffix(20))]")
            print("  \(allHex)")
            print()
        }

        // ── 2. All 0x2629 blocks (audio clip entries) for comparison ───────────
        // Only show the first 3 so we can compare structure
        print("═══ 0x2629 blocks (first 3, audio clip entries for comparison) ═══")
        for b in blocks.filter({ $0.ct == 0x2629 }).prefix(3) {
            let allHex = (0..<b.size).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            // try to find name
            var nameStr = ""
            for i in b.off ..< (b.off + b.size - 1) {
                if data[i] >= 0x20 && data[i] < 0x80 {
                    var end = i
                    while end < b.off + b.size && data[end] >= 0x20 { end += 1 }
                    let s = String(bytes: data[i..<end], encoding: .utf8) ?? ""
                    if s.count > 5 { nameStr = s; break }
                }
            }
            print("  @\(b.off) size=\(b.size) [\(nameStr.prefix(30))]")
            print("  \(allHex)")
            print()
        }

        // ── 3. The 0x262e container block ──────────────────────────────────────
        print("═══ 0x262e blocks (video clip pool) ═══")
        for b in blocks.filter({ $0.ct == 0x262e }) {
            let header = (0..<min(64, b.size)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size)")
            print("  first 64 bytes: \(header)")
            print()
        }

        // ── 4. The 0x262a container block (audio, for comparison) ──────────────
        print("═══ 0x262a blocks (audio clip pool, first 1) ═══")
        for b in blocks.filter({ $0.ct == 0x262a }).prefix(1) {
            let header = (0..<min(64, b.size)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size)")
            print("  first 64 bytes: \(header)")
        }
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
