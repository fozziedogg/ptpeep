import Foundation

// Dump the unique single-occurrence blocks that most likely hold session-level
// parameters (sample rate, bit depth, frame rate, session start TC).
// Known values: 48kHz, 24-bit, 24fps, 0:00:00:00 start TC
//
// Also dump the 0x1003/0x1004 hierarchy which wraps the 0x1001 audio-file records.

@main
struct DumpSessionHdr {
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

        func hex(_ off: Int, _ n: Int) -> String {
            (0..<min(n, data.count - off)).map { String(format: "%02x", data[off + $0]) }.joined(separator: " ")
        }

        // Dump single-occurrence blocks that are candidate session headers
        let candidates: [UInt16] = [0x1002, 0x1004, 0x1005, 0x1006, 0x1022, 0x1028, 0x103e, 0x103f, 0x1040, 0x1048, 0x1049, 0x104a, 0x104b, 0x104c, 0x104d, 0x1053, 0x2000, 0x2013, 0x2016, 0x2017, 0x2018, 0x2047, 0x2049, 0x204a, 0x204b, 0x204d, 0x2050, 0x2055, 0x2105, 0x2107, 0x2203, 0x2301, 0x2302, 0x2305, 0x230a]
        for ct in candidates {
            let matching = blocks.filter { $0.ct == ct }
            guard !matching.isEmpty else { continue }
            let b = matching[0]
            let n = min(b.size, 512)
            print(String(format: "\n0x%04x @%d size=%d:", ct, b.off, b.size))
            print("  \(hex(b.off, n))\(b.size > 512 ? " ..." : "")")

            // If it contains sub-blocks, list them
            var j = 0
            while j < b.size - 9 {
                let p = b.off + j
                guard data[p] == 0x5a else { j += 1; continue }
                let sz2 = Int(UInt32(data[p+3]) | UInt32(data[p+4]) << 8 | UInt32(data[p+5]) << 16 | UInt32(data[p+6]) << 24)
                let ct2 = UInt16(data[p+7]) | UInt16(data[p+8]) << 8
                guard sz2 > 0, sz2 < 1_000_000, p + 9 + sz2 <= b.off + b.size else { j += 1; continue }
                print(String(format: "  sub: 0x%04x @+%d size=%d  %@", ct2, j+9, sz2, hex(p+9, min(sz2, 32))))
                j += 1
            }
        }

        // Dump the 0x1004 block and its 0x1003 children in detail
        print("\n═══ 0x1004 (session audio file registry) ═══")
        if let b1004 = blocks.first(where: { $0.ct == 0x1004 }) {
            print(String(format: "0x1004 @%d size=%d", b1004.off, b1004.size))
            // The 0x1003 children wrap 0x1001 per-file records
            let b1003 = blocks.filter { $0.ct == 0x1003 && $0.off >= b1004.off && $0.off + $0.size <= b1004.off + b1004.size }
            print("  0x1003 children: \(b1003.count)")
            for (idx, b) in b1003.prefix(3).enumerated() {
                let b1001 = blocks.filter { $0.ct == 0x1001 && $0.off >= b.off && $0.off + $0.size <= b.off + b.size }
                print(String(format: "  [%d] 0x1003 @%d size=%d → %d 0x1001 records", idx, b.off, b.size, b1001.count))
                for (j, r) in b1001.prefix(2).enumerated() {
                    print(String(format: "    [%d] 0x1001 @%d size=%d: %@", j, r.off, r.size, hex(r.off, min(r.size, 32))))
                }
            }
        }

        // Dump the 0x1028 block completely (it's unique, likely the session descriptor)
        print("\n═══ 0x1028 (session descriptor?) FULL ═══")
        if let b = blocks.first(where: { $0.ct == 0x1028 }) {
            let n = b.size
            let bytes = (0..<n).map { data[b.off + $0] }
            // Print as annotated 16-byte rows
            for row in stride(from: 0, to: n, by: 16) {
                let rowBytes = bytes[row..<min(row+16, n)]
                let hexPart = rowBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                let asciiPart = rowBytes.map { ($0 >= 0x20 && $0 < 0x7f) ? Character(UnicodeScalar($0)) : "." }
                print(String(format: "  +%03d: %-47s  %@", row, hexPart, String(asciiPart)))
            }
        }

        // Look for 24fps as enum: common encodings
        // - 0x18 (24 as raw byte) near other known values
        // - In PT format the TC rate may be in the session header,
        //   possibly as enum: 0=23.976, 1=24, 2=25, 3=29.97DF, 4=29.97NDF, 5=30DF, 6=30NDF
        //   So 24fps = enum 1
        // Search for the sequence [80 bb 00 00] [?] [18] (sr, ?, bitdepth)
        // to find the session-level param block if it uses raw values
        print("\n═══ Searching for [80 bb 00 00 ?? 18] pattern ═══")
        for j in 0 ..< (data.count - 6) {
            guard data[j] == 0x80, data[j+1] == 0xbb, data[j+2] == 0x00, data[j+3] == 0x00,
                  data[j+5] == 0x18 else { continue }
            let containing = blocks.filter { $0.off <= j && j < $0.off + $0.size }
            let blockDesc = containing.suffix(3).map { String(format: "0x%04x@%d", $0.ct, $0.off) }.joined(separator: " > ")
            let post = min(data.count, j + 24)
            let postHex = (j..<post).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print("  @\(j) [\(blockDesc)]  \(postHex)")
        }

        // Search for TC rate as LE32 value 24 = 0x18000000... no.
        // More likely: look for known session start offsets
        // Session start 0:00:00:00 = 0 samples (trivial)
        // Look for a block that contains sample rate 48000 + framerate 24 + bit depth 24
        // One specific pattern: [01 00 00 00] [01 00 00 00] [18 00 00 00]
        // (enum 1 for sample rate, enum 1 for framerate 24, literal 24 for bit depth)
        print("\n═══ 0x2000 block (1 occurrence) FULL ═══")
        if let b = blocks.first(where: { $0.ct == 0x2000 }) {
            print(String(format: "0x2000 @%d size=%d", b.off, b.size))
            let n = b.size
            let bytes = (0..<n).map { data[b.off + $0] }
            for row in stride(from: 0, to: n, by: 16) {
                let rowBytes = bytes[row..<min(row+16, n)]
                let hexPart = rowBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                let asciiPart = rowBytes.map { ($0 >= 0x20 && $0 < 0x7f) ? Character(UnicodeScalar($0)) : "." }
                print(String(format: "  +%03d: %-47s  %@", row, hexPart, String(asciiPart)))
            }
        }
    }
}
