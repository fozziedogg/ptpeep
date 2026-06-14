import Foundation

// Dump every block type found inside 0x2519, with offset, size, type, and hex preview.
// Goal: find any non-0x251a, non-0x0000 blocks that might encode folder hierarchy.

struct Dump2519AllTypes {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_2519_all_types <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            fputs("No 0x2519 block\n", stderr); exit(1)
        }
        let parentStart = b2519.off
        let parentEnd   = b2519.off + b2519.size

        print("0x2519 @\(b2519.off) size=\(b2519.size)")
        print()

        let children = blocks.filter {
            $0.off >= parentStart && $0.off + $0.size <= parentEnd
        }.sorted { $0.off < $1.off }

        // Summary: count by type
        var typeCounts = [UInt16: Int]()
        for b in children { typeCounts[b.ct, default: 0] += 1 }
        print("Block types inside 0x2519:")
        for (ct, n) in typeCounts.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  0x%04x  x%d", ct, n))
        }
        print()

        // Full listing, skipping 0x251a (too many)
        print("Non-0x251a blocks (in file order):")
        print(String(format: "%-8s  %-6s  %-6s  %s", "type", "off", "size", "first 32 bytes"))
        print(String(repeating: "-", count: 80))
        for b in children where b.ct != 0x251a {
            let end = min(b.off + 32, b.off + b.size)
            let hex = (b.off..<end).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print(String(format: "0x%04x    %-8d %-6d  %@", b.ct, b.off, b.size, hex))
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

Dump2519AllTypes.run()
