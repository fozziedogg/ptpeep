import Foundation

// Dump the gap between last 0x251a and 0x251b inside 0x2519.
// This region contains 0x4422 and 0x4421 blocks — unexplored territory.

struct Dump44xx {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_4421_4422 <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            fputs("No 0x2519\n", stderr); exit(1)
        }
        let pStart = b2519.off
        let pEnd   = b2519.off + b2519.size

        // Collect 0x251a IDs for cross-reference
        var idToName = [String: String]()
        var seenNames = Set<String>()
        let sub251a = blocks.filter { $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd }
                            .sorted { $0.off < $1.off }
        var lastSub251aEnd = pStart
        for sub in sub251a {
            lastSub251aEnd = max(lastSub251aEnd, sub.off + sub.size)
            let p = sub.off
            guard p + 6 <= sub.off + sub.size else { continue }
            guard let nl = safeU32(data, at: p+2), nl >= 1, nl <= 256 else { continue }
            let nameEnd = p + 6 + Int(nl)
            guard nameEnd + 18 <= sub.off + sub.size,
                  let name = String(bytes: data[(p+6)..<nameEnd], encoding: .utf8) else { continue }
            guard seenNames.insert(name).inserted else { continue }
            let idBytes = (nameEnd+10..<nameEnd+18).map { String(format: "%02x", data[$0]) }.joined()
            idToName[idBytes] = name
        }

        // Find 0x251b start
        let b251b = blocks.filter { $0.ct == 0x251b && $0.off >= pStart && $0.off + $0.size <= pEnd }
                          .min(by: { $0.off < $1.off })
        let gapEnd = b251b.map { $0.off - 9 } ?? pEnd  // header start of 0x251b

        print("Last 0x251a ends at: \(lastSub251aEnd)")
        print("0x251b header starts at: \(gapEnd)")
        print("Gap: \(lastSub251aEnd)..\(gapEnd) = \(gapEnd - lastSub251aEnd) bytes")
        print()

        // Full hex dump of the gap
        let gapSize = gapEnd - lastSub251aEnd
        if gapSize > 0 {
            print("=== Gap hex dump ===")
            hexDump(data, from: lastSub251aEnd, count: gapSize)
            print()
        }

        // Dump each block in the gap
        let gapBlocks = blocks.filter {
            $0.off >= lastSub251aEnd && $0.off < gapEnd
        }.sorted { $0.off < $1.off }

        print("Blocks in gap (\(gapBlocks.count) found):")
        for b in gapBlocks {
            let ctStr = String(format: "0x%04x", b.ct)
            print()
            print("=== \(ctStr) @\(b.off) size=\(b.size) (hdr=\(b.off-9)) ===")
            hexDump(data, from: b.off, count: b.size)
            // Cross-reference IDs
            if b.size >= 8 {
                for i in 0...(b.size - 8) {
                    let candidate = (b.off+i..<b.off+i+8).map { String(format: "%02x", data[$0]) }.joined()
                    if let name = idToName[candidate] {
                        print("  ID match at +\(i): \"\(name)\"")
                    }
                }
            }
        }
    }

    static func hexDump(_ data: Data, from: Int, count: Int) {
        var i = 0
        while i < count {
            let rowBytes = min(16, count - i)
            let hex = (0..<rowBytes).map { String(format: "%02x", data[from + i + $0]) }.joined(separator: " ")
            let pad = String(repeating: "   ", count: 16 - rowBytes)
            let ascii = (0..<rowBytes).map { b -> String in
                let c = data[from + i + b]
                return (c >= 0x20 && c < 0x7f) ? String(UnicodeScalar(c)) : "."
            }.joined()
            let addr = String(format: "%06x", from + i)
            print("  \(addr): \((hex + pad).padding(toLength: 48, withPad: " ", startingAt: 0))  \(ascii)")
            i += rowBytes
        }
    }

    static func safeU32(_ data: Data, at i: Int) -> UInt32? {
        guard i + 4 <= data.count else { return nil }
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

Dump44xx.run()
