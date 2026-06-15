import Foundation

// Dump early session parameter blocks to find sample rate, bit depth,
// timecode rate, and session start TC.
// Known values for PeepTest.ptx: 48kHz, 24-bit, 24fps, 0:00:00:00 start
// 48000 = 0xBB80 → LE4: 80 bb 00 00
// 24-bit → likely 0x18 or enum
// 24fps → likely 0x18 or enum (same byte value — context matters)

@main
struct DumpSessionParams {
    static func main() {
        guard CommandLine.arguments.count > 1 else { exit(1) }
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

        // Dump all blocks with ct in range 0x1000-0x1010 (early session info)
        let earlyTypes: [UInt16] = [0x1000, 0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007, 0x1008, 0x1009, 0x100a, 0x100b, 0x100c, 0x100d, 0x100e, 0x100f, 0x1010]
        print("═══ Early session blocks (0x1000-0x1010) ═══")
        for ct in earlyTypes {
            let matching = blocks.filter { $0.ct == ct }
            guard !matching.isEmpty else { continue }
            for b in matching {
                let n = min(b.size, 128)
                let hex = (0..<n).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
                print(String(format: "0x%04x @%d size=%d:  %@%@", ct, b.off, b.size, hex, b.size > 128 ? " ..." : ""))
            }
        }

        // Also dump 0x2000-0x2010 range
        print("\n═══ 0x2000-0x2010 blocks ═══")
        for ct: UInt16 in 0x2000...0x2010 {
            let matching = blocks.filter { $0.ct == ct }
            guard !matching.isEmpty else { continue }
            for b in matching.prefix(3) {
                let n = min(b.size, 128)
                let hex = (0..<n).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
                print(String(format: "0x%04x @%d size=%d:  %@%@", ct, b.off, b.size, hex, b.size > 128 ? " ..." : ""))
            }
        }

        // Search for 48000 (0xBB80) as LE2, LE4
        print("\n═══ Searching for 48000 (0xbb80) LE2/LE4 ═══")
        let needle2: [UInt8] = [0x80, 0xbb]
        let needle4: [UInt8] = [0x80, 0xbb, 0x00, 0x00]
        for (label, needle) in [("LE2", needle2), ("LE4", needle4)] {
            for j in 0 ..< (data.count - needle.count) {
                guard (0..<needle.count).allSatisfy({ data[j + $0] == needle[$0] }) else { continue }
                let containing = blocks.filter { $0.off <= j && j < $0.off + $0.size }
                let blockDesc = containing.suffix(3).map { String(format: "0x%04x@%d", $0.ct, $0.off) }.joined(separator: " > ")
                let pre  = max(0, j - 8)
                let post = min(data.count, j + needle.count + 16)
                let preHex  = (pre..<j).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
                let hitHex  = (j..<j+needle.count).map { String(format: "[%02x]", data[$0]) }.joined(separator: "")
                let postHex = (j+needle.count..<post).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
                print("  \(label) @\(j) [\(blockDesc)]")
                print("  ... \(preHex) \(hitHex) \(postHex)")
            }
        }

        // Search for TC rate / sample rate as enum bytes in context
        // PT enums for sample rate: 0=44100, 1=48000, 2=88200, 3=96000, 4=176400, 5=192000
        // PT enums for bit depth: 0=16, 1=24, 2=32float
        // PT enums for TC rate: 0=23.976, 1=24, 2=25, 3=29.97DF, 4=29.97NDF, 5=30DF, 6=30NDF, 7=47.952, 8=48, 9=50, 10=59.94DF, 11=59.94NDF, 12=60
        // So for 48kHz=1, 24-bit=1, 24fps=1 — all the same byte value, useless alone
        // Try searching for sequences: [01 01 01] or nearby
        print("\n═══ Blocks that might contain session format info ═══")
        // Look for 0x2002, 0x2003, 0x2004 which often have session props
        for ct: UInt16 in [0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x200b, 0x200c] {
            let matching = blocks.filter { $0.ct == ct }
            guard !matching.isEmpty else { continue }
            for b in matching.prefix(2) {
                let n = min(b.size, 256)
                let hex = (0..<n).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
                print(String(format: "0x%04x @%d size=%d:  %@%@", ct, b.off, b.size, hex, b.size > 256 ? " ..." : ""))
            }
        }

        // Dump all unique block types and counts for overview
        print("\n═══ All block types (ct → count) ═══")
        var counts: [UInt16: Int] = [:]
        for b in blocks { counts[b.ct, default: 0] += 1 }
        let sorted = counts.sorted { $0.key < $1.key }
        for (ct, n) in sorted {
            print(String(format: "  0x%04x: %d", ct, n))
        }
    }
}
