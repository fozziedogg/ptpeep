import Foundation

// Dump the bytes inside 0x2519 BEFORE the first 0x251a block.
// Also dump the 0x251b block (folder structure) in full.

struct Dump2519Header {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_2519_header <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            fputs("No 0x2519\n", stderr); exit(1)
        }
        let pStart = b2519.off
        let pEnd   = b2519.off + b2519.size

        // Find first 0x251a inside 0x2519
        let first251a = blocks.filter { $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd }
                              .min(by: { $0.off < $1.off })

        print("0x2519 data starts at \(pStart), size=\(b2519.size)")
        if let f = first251a {
            print("First 0x251a at \(f.off) (header at \(f.off - 9))")
            let headerLen = (f.off - 9) - pStart
            print("Header section: \(pStart)..\(f.off - 10) = \(headerLen) bytes\n")
            print("=== 0x2519 header section (hex + ASCII) ===")
            hexDump(data, from: pStart, count: headerLen)
        }

        // Dump 0x251b block in full
        print()
        if let b251b = blocks.first(where: { $0.ct == 0x251b && $0.off >= pStart && $0.off + $0.size <= pEnd }) {
            print("=== 0x251b block @\(b251b.off) size=\(b251b.size) ===")
            hexDump(data, from: b251b.off, count: b251b.size)
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

Dump2519Header.run()
