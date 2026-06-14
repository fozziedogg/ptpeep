import Foundation

// List every block type found in the file, with counts and first occurrence offset.
// Also dump all blocks INSIDE 0x2519 that are NOT 0x251a.

struct DumpAllBlocks {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_all_blocks <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // Summary of all block types
        var typeCounts  = [UInt16: Int]()
        var typeFirstOff = [UInt16: Int]()
        for b in blocks {
            typeCounts[b.ct, default: 0] += 1
            if typeFirstOff[b.ct] == nil { typeFirstOff[b.ct] = b.off }
        }
        print("All block types in file:")
        for ct in typeCounts.keys.sorted() {
            print(String(format: "  0x%04x  count=%-4d  first_off=%d", ct, typeCounts[ct]!, typeFirstOff[ct]!))
        }
        print()

        // Non-0x251a blocks inside 0x2519
        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            fputs("No 0x2519\n", stderr); exit(1)
        }
        let pStart = b2519.off
        let pEnd   = b2519.off + b2519.size

        let others = blocks.filter {
            $0.ct != 0x251a &&
            $0.off >= pStart &&
            $0.off + $0.size <= pEnd
        }
        print("Non-0x251a blocks inside 0x2519 (\(others.count) found):")
        for b in others.sorted(by: { $0.off < $1.off }) {
            let previewEnd = min(b.off + 32, b.off + b.size)
            let hex = (b.off..<previewEnd).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print(String(format: "  0x%04x @%-6d size=%-5d  %@", b.ct, b.off, b.size, hex))
        }
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

DumpAllBlocks.run()
