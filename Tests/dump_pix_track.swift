import Foundation

// The PIX video track is the first 0x261c block inside 0x2624 (size=3040).
// It contains a 0x261b sub-block (size=2475). The clip placements should
// follow the 0x261b. Dump the full PIX 0x261c block and highlight the part
// after the 0x261b ends.
// Also dump the first audio 0x261c (Printmaster.dup1, @281277) for comparison.

@main
struct DumpPixTrack {
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

        guard let b2624 = blocks.first(where: { $0.ct == 0x2624 }) else { print("no 0x2624"); return }
        let lo = b2624.off, hi = b2624.off + b2624.size

        let b261c = blocks.filter { $0.ct == 0x261c && $0.off >= lo && $0.off + $0.size <= hi }
        print("Total 0x261c inside 0x2624: \(b261c.count)")

        for (idx, b) in b261c.enumerated() {
            // Read track name from nested 0x261b → 0x102d → 0x2619
            // First bytes of 0x261c content are the 0x261b block header (9 bytes), then 0x261b data
            // Inside 0x261b, first block is 0x102d. Inside 0x102d, first is 0x2619.
            // 0x2619 content: [u32 nameLen][name]
            // Total path: +9 (261b hdr) +9 (102d hdr) +9 (2619 hdr) = +27, then nameLen u32
            let nameOff = b.off + 9 + 9 + 9
            var trackName = "?"
            if nameOff + 4 <= data.count {
                let nl = Int(UInt32(data[nameOff]) | UInt32(data[nameOff+1]) << 8 | UInt32(data[nameOff+2]) << 16 | UInt32(data[nameOff+3]) << 24)
                if nl >= 1, nl <= 256, nameOff + 4 + nl <= data.count {
                    trackName = String(bytes: data[nameOff+4 ..< nameOff+4+nl], encoding: .utf8) ?? "?"
                }
            }

            // Find the 0x261b sub-block size to know where the "tail" starts
            let b261bSize: Int
            if b.off + 8 <= data.count {
                b261bSize = Int(UInt32(data[b.off+3]) | UInt32(data[b.off+4]) << 8 | UInt32(data[b.off+5]) << 16 | UInt32(data[b.off+6]) << 24)
            } else { b261bSize = 0 }
            let tailStart = 9 + b261bSize  // offset within b.off
            let tailSize  = b.size - tailStart

            print("\n[\(idx)] 0x261c @\(b.off) size=\(b.size) track='\(trackName)'")
            print("  0x261b sub-block size: \(b261bSize), tail offset: +\(tailStart), tail bytes: \(tailSize)")

            if tailSize > 0 {
                let n = min(tailSize, 256)
                let hex = (0..<n).map { String(format: "%02x", data[b.off + tailStart + $0]) }.joined(separator: " ")
                print("  TAIL: \(hex)\(tailSize > 256 ? " ..." : "")")

                // Also scan for 0x5a block markers in the tail
                print("  Block markers in tail:")
                for j in 0 ..< (tailSize - 9) {
                    let p = b.off + tailStart + j
                    guard data[p] == 0x5a else { continue }
                    let sz2 = Int(UInt32(data[p+3]) | UInt32(data[p+4]) << 8 | UInt32(data[p+5]) << 16 | UInt32(data[p+6]) << 24)
                    let ct2 = UInt16(data[p+7]) | UInt16(data[p+8]) << 8
                    guard sz2 > 0, sz2 < 100_000, p + 9 + sz2 <= b.off + b.size else { continue }
                    let hex2 = (9..<min(9+sz2, 9+48)).map { String(format: "%02x", data[p + $0]) }.joined(separator: " ")
                    print(String(format: "    @+%d ct=0x%04x size=%d  %@", j, ct2, sz2, hex2))
                }
            }
        }
    }
}
