import Foundation

// Anchor to known track names in the 0x2519 header, show ±12 bytes context.
// This lets us read the entry structure empirically.

struct DumpHeaderNames {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static let names: [(String, [UInt8])] = [
        ("Solo_A",          [0x53,0x6f,0x6c,0x6f,0x5f,0x41]),
        ("ƒ BASIC_OUTER",   [0xc6,0x92,0x20,0x42,0x41,0x53,0x49,0x43,0x5f,0x4f,0x55,0x54,0x45,0x52]),
        ("OuterMember",     [0x4f,0x75,0x74,0x65,0x72,0x4d,0x65,0x6d,0x62,0x65,0x72]),
        ("ƒ BASIC_Inner",   [0xc6,0x92,0x20,0x42,0x41,0x53,0x49,0x43,0x5f,0x49,0x6e,0x6e,0x65,0x72]),
        ("InnerMember",     [0x49,0x6e,0x6e,0x65,0x72,0x4d,0x65,0x6d,0x62,0x65,0x72]),
        ("Aux_Top",         [0x41,0x75,0x78,0x5f,0x54,0x6f,0x70]),
        ("AuxMember",       [0x41,0x75,0x78,0x4d,0x65,0x6d,0x62,0x65,0x72]),
        ("Aux_Nested",      [0x41,0x75,0x78,0x5f,0x4e,0x65,0x73,0x74,0x65,0x64]),
        ("AuxNestedMember", [0x41,0x75,0x78,0x4e,0x65,0x73,0x74,0x65,0x64,0x4d,0x65,0x6d,0x62,0x65,0x72]),
        ("Solo_B",          [0x53,0x6f,0x6c,0x6f,0x5f,0x42]),
    ]

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_header_names <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }),
              let first251a = blocks.filter({ $0.ct == 0x251a && $0.off >= b2519.off && $0.off + $0.size <= b2519.off + b2519.size })
                                    .min(by: { $0.off < $1.off }) else {
            fputs("Missing blocks\n", stderr); exit(1)
        }
        let pStart  = b2519.off
        let hdrEnd  = first251a.off - 9
        let hdrData = data[pStart..<hdrEnd]

        print("Header: \(pStart)..\(hdrEnd)  (\(hdrEnd-pStart) bytes)\n")

        let PRE = 12; let POST = 20

        for (label, needle) in names {
            // find all occurrences in header
            var found = [Int]()
            outer: for i in 0...(hdrData.count - needle.count) {
                for j in 0..<needle.count {
                    if hdrData[hdrData.startIndex + i + j] != needle[j] { continue outer }
                }
                found.append(pStart + i)
            }
            guard let pos = found.first else { print("NOT FOUND: \(label)"); continue }

            let from = max(pStart, pos - PRE)
            let to   = min(hdrEnd, pos + needle.count + POST)
            let preBytes  = (from..<pos).map { String(format: "%02x", data[$0]) }
            let nameBytes = (pos..<(pos+needle.count)).map { String(format: "%02x", data[$0]) }
            let postBytes = ((pos+needle.count)..<to).map { String(format: "%02x", data[$0]) }

            print("[\(label)] @\(pos)")
            print("  PRE : \(preBytes.joined(separator: " "))")
            print("  NAME: \(nameBytes.joined(separator: " "))")
            print("  POST: \(postBytes.joined(separator: " "))")
            print()
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

DumpHeaderNames.run()
