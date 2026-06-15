import Foundation

// Dump full post-name bytes for each 0x251a, side-by-side, for depth analysis.
// Groups: solo tracks vs folder tracks vs member tracks at different depths.

struct DumpPostbytesFull {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_postbytes_full <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            fputs("No 0x2519\n", stderr); exit(1)
        }
        let pStart = b2519.off
        let pEnd   = b2519.off + b2519.size

        let subBlocks = blocks.filter {
            $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd
        }.sorted { $0.off < $1.off }

        var seen = Set<String>()
        for sub in subBlocks {
            let p = sub.off
            guard p + 6 <= sub.off + sub.size else { continue }
            let tc = UInt16(data[p]) | UInt16(data[p+1]) << 8
            guard let nl = safeU32(data, at: p+2), nl >= 1, nl <= 256 else { continue }
            let nameEnd = p + 6 + Int(nl)
            guard nameEnd <= sub.off + sub.size,
                  let name = String(bytes: data[(p+6)..<nameEnd], encoding: .utf8) else { continue }
            guard seen.insert(name).inserted else { continue }

            let folderFlag = (nameEnd + 53 < sub.off + sub.size) ? data[nameEnd + 53] : 0
            let tcStr = String(format: "0x%04x", tc)
            let fldStr = folderFlag != 0 ? "FOLDER" : "track "
            let blockEnd = sub.off + sub.size
            let postCount = blockEnd - nameEnd
            let postBytes = (nameEnd..<blockEnd).map { String(format: "%02x", data[$0]) }

            print("[\(fldStr) tc=\(tcStr)]  \(name)")
            print("  post[\(postCount)]: \(postBytes.joined(separator: " "))")
            print()
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

DumpPostbytesFull.run()
