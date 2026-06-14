import Foundation

// Search for known PIX clip position values:
// en_2 start=35966000 (0x224CC30), end=50352000 (0x3004F80), len=14386000 (0xDB8350)

@main
struct DumpPixPosition {
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

        // Try both 4-byte and 3-byte LE needles for each value
        let needles: [(String, [UInt8])] = [
            ("start=35966000 LE4",  [0x30, 0xCC, 0x24, 0x02]),
            ("start=35966000 LE3",  [0x30, 0xCC, 0x24]),
            ("end=50352000 LE4",    [0x80, 0x4F, 0x00, 0x03]),
            ("end=50352000 LE3",    [0x80, 0x4F, 0x00]),
            ("len=14386000 LE4",    [0x50, 0x83, 0xDB, 0x00]),
            ("len=14386000 LE3",    [0x50, 0x83, 0xDB]),
        ]

        for (label, needle) in needles {
            var hits: [Int] = []
            for j in 0 ..< (data.count - needle.count) {
                if (0..<needle.count).allSatisfy({ data[j + $0] == needle[$0] }) {
                    hits.append(j)
                }
            }
            print("\n\(label): \(hits.count) hits")
            for hit in hits {
                let containing = blocks.filter { $0.off <= hit && hit < $0.off + $0.size }
                let blockDesc = containing.suffix(3).map { String(format: "0x%04x@%d", $0.ct, $0.off) }.joined(separator: " > ")
                // Show 16 bytes before and 24 after
                let pre  = max(0, hit - 16)
                let post = min(data.count, hit + needle.count + 24)
                let preHex  = (pre..<hit).map            { String(format: "%02x", data[$0]) }.joined(separator: " ")
                let hitHex  = (hit..<hit+needle.count).map { String(format: "[%02x]", data[$0]) }.joined(separator: "")
                let postHex = (hit+needle.count..<post).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
                print("  @\(hit)  \(blockDesc)")
                print("  ... \(preHex) \(hitHex) \(postHex)")
            }
        }
    }
}
