import Foundation

// Search the entire file for every 8-byte track ID from 0x251a.
// Report every block type that contains each ID, at what offset within that block.
// This should reveal if any other block stores parent-child relationships via IDs.

struct DumpIdSearch {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_id_search <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            fputs("No 0x2519\n", stderr); exit(1)
        }
        let pStart = b2519.off, pEnd = b2519.off + b2519.size

        // Extract track IDs from 0x251a blocks
        var trackIds: [(name: String, id: [UInt8])] = []
        var seen = Set<String>()
        for sub in blocks.filter({ $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd })
                         .sorted(by: { $0.off < $1.off }) {
            let p = sub.off
            guard p + 6 <= sub.off + sub.size else { continue }
            guard let nl = safeU32(data, at: p+2), nl >= 1, nl <= 256 else { continue }
            let nameEnd = p + 6 + Int(nl)
            guard nameEnd + 18 <= sub.off + sub.size,
                  let name = String(bytes: data[(p+6)..<nameEnd], encoding: .utf8) else { continue }
            guard seen.insert(name).inserted else { continue }
            let id = (nameEnd+10..<nameEnd+18).map { data[$0] }
            trackIds.append((name: name, id: id))
        }

        print("Searching for \(trackIds.count) track IDs across \(blocks.count) blocks...\n")

        for (name, id) in trackIds {
            let idHex = id.map { String(format: "%02x", $0) }.joined()
            var hits: [(ctStr: String, off: Int, blockOff: Int, blockSize: Int)] = []

            for b in blocks {
                guard b.size >= 8 else { continue }
                for i in 0...(b.size - 8) {
                    var match = true
                    for j in 0..<8 {
                        if data[b.off + i + j] != id[j] { match = false; break }
                    }
                    if match {
                        let ctStr = String(format: "0x%04x", b.ct)
                        hits.append((ctStr: ctStr, off: b.off + i, blockOff: b.off, blockSize: b.size))
                    }
                }
            }

            // Filter out matches that are IN the 0x251a block itself (or its embedding 0x4420)
            // Show all unique block types that contain this ID
            var outsideTypes = [String: [Int]]()
            for h in hits {
                // Skip 0x251a blocks (that's where we got the ID from)
                if h.ctStr == "0x251a" { continue }
                outsideTypes[h.ctStr, default: []].append(h.off - h.blockOff)
            }

            if outsideTypes.isEmpty {
                print("\(name) (\(idHex)): only in 0x251a")
            } else {
                print("\(name) (\(idHex)):")
                for (ct, offsets) in outsideTypes.sorted(by: { $0.key < $1.key }) {
                    print("  \(ct) at offsets within block: \(offsets)")
                }
            }
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

DumpIdSearch.run()
