import Foundation

// Dump the inside of the PIX track's 0x261b block (@278239, size=2475)
// and the Printmaster.dup1's 0x261b (@281286+9=281295, size=1317) for comparison.
// After the initial 0x102d sub-block, the clip placements should be there.

@main
struct DumpPix261b {
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

        // PIX 0x261b starts at 278239, size=2475
        // Printmaster.dup1 0x261b starts at 281295, size=1317
        let targets: [(String, Int, Int)] = [
            ("PIX",               278239, 2475),
            ("Printmaster.dup1",  281295, 1317),
        ]

        for (name, off, size) in targets {
            print("\n═══ \(name) 0x261b @\(off) size=\(size) ═══")

            // Find the initial 0x102d sub-block and its size
            guard off + 8 <= data.count, data[off] == 0x5a else {
                print("  Not a block marker"); continue
            }
            let subCt   = UInt16(data[off+7]) | UInt16(data[off+8]) << 8
            let subSize = Int(UInt32(data[off+3]) | UInt32(data[off+4]) << 8 | UInt32(data[off+5]) << 16 | UInt32(data[off+6]) << 24)
            print(String(format: "  First sub-block: ct=0x%04x size=%d", subCt, subSize))

            // After 0x102d: offset = 9 + subSize
            let afterSub = 9 + subSize
            let remaining = size - afterSub
            print("  Remaining after first sub-block: \(remaining) bytes at +\(afterSub)")

            if remaining > 0 {
                let remStart = off + afterSub
                let n = min(remaining, 512)
                let hex = (0..<n).map { String(format: "%02x", data[remStart + $0]) }.joined(separator: " ")
                print("  DATA: \(hex)\(remaining > 512 ? " ..." : "")")

                // Scan for block markers
                print("  Block markers in remaining:")
                var j = 0
                while j < remaining - 9 {
                    let p = remStart + j
                    guard data[p] == 0x5a else { j += 1; continue }
                    let sz2 = Int(UInt32(data[p+3]) | UInt32(data[p+4]) << 8 | UInt32(data[p+5]) << 16 | UInt32(data[p+6]) << 24)
                    let ct2 = UInt16(data[p+7]) | UInt16(data[p+8]) << 8
                    guard sz2 > 0, sz2 < 100_000, p + 9 + sz2 <= off + size else { j += 1; continue }
                    let hex2 = (9..<min(9+sz2, 9+48)).map { String(format: "%02x", data[p + $0]) }.joined(separator: " ")
                    print(String(format: "    @+%d ct=0x%04x size=%d  %@", j, ct2, sz2, hex2))
                    j += 1
                }
            }
        }
    }
}
