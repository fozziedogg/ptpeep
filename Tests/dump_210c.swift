import Foundation

// Dump 0x210c block with ID cross-references.
// Also dump 0x263b blocks (basic folder blocks).

struct Dump210c {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_210c <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // Collect track IDs from 0x251a
        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else { fputs("No 0x2519\n", stderr); exit(1) }
        let pStart = b2519.off, pEnd = b2519.off + b2519.size
        var idToName = [String: String]()
        var nameToId = [String: [UInt8]]()
        var seenNames = Set<String>()
        for sub in blocks.filter({ $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd }).sorted(by: { $0.off < $1.off }) {
            let p = sub.off
            guard p + 6 <= sub.off + sub.size else { continue }
            guard let nl = safeU32(data, at: p+2), nl >= 1, nl <= 256 else { continue }
            let nameEnd = p + 6 + Int(nl)
            guard nameEnd + 18 <= sub.off + sub.size,
                  let name = String(bytes: data[(p+6)..<nameEnd], encoding: .utf8) else { continue }
            guard seenNames.insert(name).inserted else { continue }
            let id = (nameEnd+10..<nameEnd+18).map { data[$0] }
            let idHex = id.map { String(format: "%02x", $0) }.joined()
            idToName[idHex] = name
            nameToId[name] = id
        }

        // Dump 0x210c block(s)
        print("=== 0x210c blocks ===")
        for b in blocks.filter({ $0.ct == 0x210c }).sorted(by: { $0.off < $1.off }) {
            print("\n0x210c @\(b.off) size=\(b.size)")
            hexDump(data, from: b.off, count: b.size, idMap: idToName)
            crossRef(data, block: b, idMap: idToName)
        }

        // Dump 0x263b blocks
        print("\n=== 0x263b blocks ===")
        for b in blocks.filter({ $0.ct == 0x263b }).sorted(by: { $0.off < $1.off }) {
            print("\n0x263b @\(b.off) size=\(b.size)")
            hexDump(data, from: b.off, count: b.size, idMap: idToName)
            crossRef(data, block: b, idMap: idToName)
        }

        // Also dump 0x261c (audio track blocks)
        print("\n=== 0x261c blocks ===")
        for b in blocks.filter({ $0.ct == 0x261c }).sorted(by: { $0.off < $1.off }) {
            print("\n0x261c @\(b.off) size=\(b.size)")
            hexDump(data, from: b.off, count: b.size, idMap: idToName)
            crossRef(data, block: b, idMap: idToName)
        }
    }

    static func crossRef(_ data: Data, block b: Block, idMap: [String: String]) {
        var hits = [(offset: Int, name: String)]()
        guard b.size >= 8 else { return }
        for i in 0...(b.size - 8) {
            let candidate = (b.off+i..<b.off+i+8).map { String(format: "%02x", data[$0]) }.joined()
            if let name = idMap[candidate] {
                hits.append((offset: i, name: name))
            }
        }
        if !hits.isEmpty {
            print("  IDs found:")
            for h in hits { print("    @+\(h.offset): \"\(h.name)\"") }
        }
    }

    static func hexDump(_ data: Data, from: Int, count: Int, idMap: [String: String]) {
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

Dump210c.run()
