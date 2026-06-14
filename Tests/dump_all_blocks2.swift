import Foundation

// List ALL block types in the ENTIRE file, outside 0x2519 too.
// Also look for any blocks containing the known 8-byte track IDs.

struct DumpAllBlocks2 {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_all_blocks2 <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // Summary of all block types
        var counts = [UInt16: Int]()
        var firstOff = [UInt16: Int]()
        var sizes    = [UInt16: (Int, Int)]() // (min, max)
        for b in blocks {
            counts[b.ct, default: 0] += 1
            if firstOff[b.ct] == nil { firstOff[b.ct] = b.off }
            let (lo, hi) = sizes[b.ct] ?? (b.size, b.size)
            sizes[b.ct] = (min(lo, b.size), max(hi, b.size))
        }
        print("ALL block types in file (\(blocks.count) total blocks, \(counts.count) unique types):")
        for ct in counts.keys.sorted() {
            let (lo, hi) = sizes[ct]!
            let szRange = lo == hi ? "\(lo)" : "\(lo)..\(hi)"
            print(String(format: "  0x%04x  count=%-4d  first_off=%-6d  size=%@",
                ct, counts[ct]!, firstOff[ct]!, szRange))
        }

        // Blocks OUTSIDE 0x2519
        print()
        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            fputs("No 0x2519\n", stderr); exit(1)
        }
        let p2519Start = b2519.off
        let p2519End   = b2519.off + b2519.size

        let outside = blocks.filter { $0.off < p2519Start || $0.off >= p2519End }
        var outsideTypes = [UInt16: Int]()
        for b in outside { outsideTypes[b.ct, default: 0] += 1 }
        print("Block types OUTSIDE 0x2519 (\(outside.count) blocks):")
        for ct in outsideTypes.keys.sorted() {
            print(String(format: "  0x%04x  count=%d", ct, outsideTypes[ct]!))
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

DumpAllBlocks2.run()
