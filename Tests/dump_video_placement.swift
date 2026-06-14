import Foundation

// Look for video clip TIMELINE placement blocks.
// Candidates: 0x2625 (129 instances) and 0x2626 (143 instances).
// Also look at what's near 0x2624 (the 240KB video track block) to find playlist entries.

let baseNeedle = Array("Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole".utf8)
let pixNeedle  = Array("PIX".utf8)

@main
struct DumpVideoPlacement {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_video_placement <file.ptx>\n", stderr); exit(1)
        }
        let url  = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw  = try! Data(contentsOf: url)
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // ── 1. Sample of 0x2625 blocks ────────────────────────────────────────
        print("═══ 0x2625 blocks (first 5 and any containing video name) ═══")
        let b2625 = blocks.filter { $0.ct == 0x2625 }
        print("  Total 0x2625: \(b2625.count)")
        for b in b2625.prefix(5) {
            let allHex = (0..<min(b.size, 64)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            let hasV = containsNeedle(data, in: b, needle: baseNeedle)
            print("  @\(b.off) size=\(b.size) hasVideo=\(hasV):  \(allHex)")
        }

        // ── 2. Sample of 0x2626 blocks ────────────────────────────────────────
        print("\n═══ 0x2626 blocks (first 5) ═══")
        let b2626 = blocks.filter { $0.ct == 0x2626 }
        print("  Total 0x2626: \(b2626.count)")
        for b in b2626.prefix(5) {
            let allHex = (0..<min(b.size, 64)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size):  \(allHex)")
        }

        // ── 3. What's in the 240KB 0x2624 block beyond the first 0x2623? ──────
        // The 0x2624 at 277738 contains 0x2623 sub-blocks.
        // Show the first 512 bytes to understand the count/structure.
        print("\n═══ 0x2624 block first 512 bytes ═══")
        if let b = blocks.first(where: { $0.ct == 0x2624 }) {
            let n = min(b.size, 512)
            let allHex = (0..<n).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size)")
            print("  \(allHex)")

            // Count nested 0x2623 blocks within this range
            print("\n  Sub-blocks inside 0x2624:")
            let subBlocks = blocks.filter {
                $0.ct == 0x2623 &&
                $0.off >= b.off &&
                $0.off + $0.size <= b.off + b.size
            }
            print("  0x2623 sub-blocks: \(subBlocks.count)")

            // What other block types are inside 0x2624?
            var ctCounts: [UInt16: Int] = [:]
            for sb in blocks.filter({ $0.off >= b.off && $0.off + $0.size <= b.off + b.size }) {
                ctCounts[sb.ct, default: 0] += 1
            }
            let sorted = ctCounts.sorted { $0.key < $1.key }
            print("  All nested types: \(sorted.map { String(format: "0x%04x×%d", $0.key, $0.value) }.joined(separator: " "))")
        }

        // ── 4. Look for 0x2625/0x2626 inside the 0x2624 block ────────────────
        print("\n═══ 0x2625 + 0x2626 inside 0x2624 ═══")
        if let b2624 = blocks.first(where: { $0.ct == 0x2624 }) {
            let inner2625 = blocks.filter { $0.ct == 0x2625 && $0.off >= b2624.off && $0.off + $0.size <= b2624.off + b2624.size }
            let inner2626 = blocks.filter { $0.ct == 0x2626 && $0.off >= b2624.off && $0.off + $0.size <= b2624.off + b2624.size }
            print("  0x2625 inside 0x2624: \(inner2625.count)")
            print("  0x2626 inside 0x2624: \(inner2626.count)")
            for b in inner2625.prefix(3) {
                let allHex = (0..<min(b.size, 64)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
                print("  0x2625 @\(b.off) size=\(b.size):  \(allHex)")
            }
            for b in inner2626.prefix(3) {
                let allHex = (0..<min(b.size, 64)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
                print("  0x2626 @\(b.off) size=\(b.size):  \(allHex)")
            }
        }

        // ── 5. 0x1052 blocks (audio track playlists) — show all names ─────────
        print("\n═══ 0x1052 blocks (all audio track playlists) ═══")
        for b in blocks.filter({ $0.ct == 0x1052 }) {
            let pos = b.off
            if let nl = u32LE(data, at: pos), nl >= 1, nl <= 64,
               pos + 4 + Int(nl) <= data.count,
               let name = String(bytes: data[pos+4..<pos+4+Int(nl)], encoding: .utf8) {
                // count of clip placements at offset 4+nl (next u32)
                let countOff = pos + 4 + Int(nl)
                let count = countOff + 4 <= data.count ? u32LE(data, at: countOff) ?? 0 : 0
                print("  @\(b.off) size=\(b.size) track='\(name)' clipCount=\(count)")
            }
        }

        // ── 6. 0x104f blocks near the 0x2624 range (video playlist?) ─────────
        // Check if 0x2624 contains anything resembling 0x104f-like structures
        print("\n═══ 0x103d / 0x103e / 0x103f blocks (potential video playlist types) ═══")
        for ct in [UInt16(0x103d), 0x103e, 0x103f] {
            for b in blocks.filter({ $0.ct == ct }) {
                let allHex = (0..<min(b.size, 48)).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
                print(String(format: "  0x%04x @%d size=%d:  %@", ct, b.off, b.size, allHex))
            }
        }
    }

    static func containsNeedle(_ data: Data, in b: Block, needle: [UInt8]) -> Bool {
        guard b.size > needle.count else { return false }
        for i in b.off ..< (b.off + b.size - needle.count) {
            if (0..<needle.count).allSatisfy({ data[i + $0] == needle[$0] }) { return true }
        }
        return false
    }

    static func u32LE(_ d: Data, at i: Int) -> UInt32? {
        guard i + 4 <= d.count else { return nil }
        return UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
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
