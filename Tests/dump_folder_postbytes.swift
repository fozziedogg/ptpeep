import Foundation

// Dump full 66 post-bytes for ALL folder tracks (tc=0x000b and tc=0x0002) from 0x251a blocks.
// Goal: find a byte that distinguishes top-level from nested tc=0x000b basic folders.

struct DumpFolderPostBytes {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_folder_postbytes <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            fputs("No 0x2519 block found\n", stderr); exit(1)
        }
        let parentStart = b2519.off
        let parentEnd   = b2519.off + b2519.size

        let subBlocks = blocks.filter {
            $0.ct == 0x251a && $0.off >= parentStart && $0.off + $0.size <= parentEnd
        }

        var seenNames = Set<String>()

        for (i, sub) in subBlocks.enumerated() {
            let p = sub.off
            guard p + 6 <= sub.off + sub.size else { continue }

            let typeCode = UInt16(data[p]) | UInt16(data[p + 1]) << 8
            guard let nl = safeU32(data, at: p + 2), nl >= 1, nl <= 256 else { continue }
            let nameLen = Int(nl)
            let nameStart = p + 6
            let nameEnd   = nameStart + nameLen
            guard nameEnd <= sub.off + sub.size,
                  let name = String(bytes: data[nameStart..<nameEnd], encoding: .utf8) else { continue }

            // First occurrence only
            guard seenNames.insert(name).inserted else { continue }

            // Only dump folder tracks (tc=0x000b) plus all tc=0x0002 for comparison
            // Also dump tracks adjacent to folders of interest
            let isBasicFolder   = typeCode == 0x000b
            let isRoutingFolder = typeCode == 0x0002

            if !isBasicFolder && !isRoutingFolder { continue }

            // Read all 66 post-bytes
            let postStart = nameEnd
            let postEnd   = min(postStart + 66, sub.off + sub.size)
            let post = (postStart..<postEnd).map { data[$0] }

            // Format post bytes in rows of 16
            let p62 = postEnd >= postStart + 63 ? (Int(post[62]) | Int(post[63]) << 8) : -1
            let folderFlag = post.count > 53 ? post[53] : 0xff

            print(String(format: "[%3d] tc=0x%04x  fld=%02x  p0=%02x  p62=0x%04x  \"%@\"",
                         i, typeCode, folderFlag, post.isEmpty ? 0xff : post[0],
                         p62 < 0 ? 0xffff : p62, name))

            // Print all 66 post bytes in rows of 16
            for row in stride(from: 0, to: post.count, by: 16) {
                let slice = post[row..<min(row+16, post.count)]
                let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
                let idxLabel = String(format: "  p[%2d]:", row)
                print("\(idxLabel) \(hex)")
            }
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

DumpFolderPostBytes.run()
