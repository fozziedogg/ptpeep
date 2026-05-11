import Foundation

// Dump all 0x251a track display blocks to find where the color index is stored.
// For each track, prints name, type code, and ALL bytes from the end of the name
// onward — so we can cross-reference against known Pro Tools track colors.
//
// Usage: swiftc dump_251a_colors.swift -o dump_251a_colors && ./dump_251a_colors <file.ptx>

@main
struct Dump251aColors {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_251a_colors <file.ptx>\n", stderr); exit(1)
        }
        let url  = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw  = try! Data(contentsOf: url)
        guard let data = xorDecode(raw) else { fputs("Not a PT 10+ file\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            print("No 0x2519 block"); return
        }
        let pStart = b2519.off, pEnd = b2519.off + b2519.size
        let subs = blocks.filter { $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd }
        print("Found \(subs.count) 0x251a sub-blocks\n")

        for sub in subs {
            let p = sub.off
            guard p + 6 <= sub.off + sub.size else { continue }
            let typeCode = UInt16(data[p]) | UInt16(data[p+1]) << 8
            guard let nl = u32LE(data, at: p + 2), nl >= 1, nl <= 256 else { continue }
            let nameEnd = p + 6 + Int(nl)
            guard nameEnd <= sub.off + sub.size,
                  let name = String(bytes: data[(p+6)..<nameEnd], encoding: .utf8) else { continue }

            // Print all bytes from end-of-name to end-of-block, annotated with relative offset
            let tail = nameEnd
            let tailEnd = sub.off + sub.size
            let tailBytes = tailEnd - tail
            print("[\(name)] type=0x\(String(format: "%04x", typeCode)) name_len=\(nl) tail_bytes=\(tailBytes)")

            // Print bytes in groups of 16 with offset annotations
            var i = 0
            while i < tailBytes {
                let n = min(16, tailBytes - i)
                let hexPart = (0..<n).map { String(format: "%02x", data[tail + i + $0]) }.joined(separator: " ")
                print(String(format: "  +%3d: %@", i, hexPart))
                i += 16
            }
            print()
        }
    }

    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func u32LE(_ d: Data, at i: Int) -> UInt32? {
        guard i + 4 <= d.count else { return nil }
        return UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
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
        var d = raw
        let chunkSize = 4096
        for chunk in stride(from: chunkSize, to: raw.count, by: chunkSize) {
            let xb = t[(chunk >> 12) & 0xff]; guard xb != 0 else { continue }
            let end = min(chunk + chunkSize, raw.count)
            for i in chunk..<end { d[i] = raw[i] ^ xb }
        }
        return d
    }
}
