import Foundation

// Parse the 0x2519 header section (before first 0x251a) as a compact track listing.
// Goal: find the field before each tc value — hypothesis: it encodes nesting depth.
//
// Observed structure:
//   [u32 version=1][10 zeros][u32 count]
//   then count × entries, each:
//     [??? prefix] [u16 tc] [u32 nameLen] [name bytes] [separator] [u32 0x2a] [8-byte ID]

struct Dump2519Entries {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_2519_entries <file.ptx>\n", stderr); exit(1)
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
        guard let first251a = blocks.filter({ $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd })
                                    .min(by: { $0.off < $1.off }) else {
            fputs("No 0x251a inside 0x2519\n", stderr); exit(1)
        }

        // Header section ends 9 bytes before the first 0x251a block (the 9-byte block header)
        let headerEnd = first251a.off - 9
        let headerLen = headerEnd - pStart
        print("0x2519 header section: \(pStart)..\(headerEnd) (\(headerLen) bytes)")
        print()

        // Raw hex dump for reference
        print("=== Raw hex ===")
        hexDump(data, from: pStart, count: headerLen)
        print()

        // Parse header
        var pos = pStart

        // u32 version
        guard pos + 4 <= headerEnd else { fputs("Header too short for version\n", stderr); exit(1) }
        let version = u32le(data, at: pos); pos += 4
        print("version field: \(version)")

        // skip 10 zero bytes
        pos += 10

        // u32 count
        guard pos + 4 <= headerEnd else { fputs("Header too short for count\n", stderr); exit(1) }
        let count = Int(u32le(data, at: pos)); pos += 4
        print("track count: \(count)")
        print()

        // Parse entries
        print("idx    prefix          tc      nLen  name")
        print(String(repeating: "-", count: 60))

        for i in 0..<count {
            guard pos < headerEnd else {
                print("  [ran out of data at entry \(i)]"); break
            }

            // Dump the next 32 bytes to see entry structure
            let preview = min(32, headerEnd - pos)
            let previewHex = (0..<preview).map { String(format: "%02x", data[pos + $0]) }.joined(separator: " ")

            // Try to find tc by locating nameLen:
            // Scan forward for a u16 we recognise (0x0000, 0x0002, 0x0009, 0x000b)
            // preceded by some prefix bytes, followed by valid nameLen + name
            var entryStart = pos
            var found = false

            for skip in 0...16 {
                let tcOff = entryStart + skip
                guard tcOff + 2 + 4 <= headerEnd else { break }
                let tc = UInt16(data[tcOff]) | UInt16(data[tcOff+1]) << 8
                guard tc == 0x0000 || tc == 0x0002 || tc == 0x0009 || tc == 0x000b else { continue }
                let nl = u32le(data, at: tcOff + 2)
                guard nl >= 1, nl <= 128 else { continue }
                let nameEnd = tcOff + 6 + Int(nl)
                guard nameEnd <= headerEnd else { continue }
                guard let name = String(bytes: data[(tcOff+6)..<nameEnd], encoding: .utf8),
                      name.allSatisfy({ $0.isASCII && ($0.isPunctuation || $0.isLetter || $0.isNumber || $0 == " " || $0 == "_") })
                else { continue }

                // Found plausible entry
                let prefix = (0..<skip).map { String(format: "%02x", data[entryStart + $0]) }.joined(separator: " ")
                let tcStr  = String(format: "0x%04x", tc)
                let idxStr = String(i).padding(toLength: 5, withPad: " ", startingAt: 0)
                print("\(idxStr)  [\(prefix)]  \(tcStr)  nl=\(nl)  \"\(name)\"")

                // Advance past this entry — scan for next separator pattern
                // After name there are 6 separator bytes, then u32 0x2a, then 8-byte ID = 18 bytes
                let afterName = nameEnd
                // Try to detect separator + 0x2a + 8-byte id = 18 bytes
                pos = afterName + 18
                found = true
                break
            }

            if !found {
                print("  [entry \(i) at +\(pos - pStart): could not parse — bytes: \(previewHex)]")
                // Try to recover by advancing 1 byte
                pos += 1
            }
        }

        print()
        print("Remaining bytes in header: \(headerEnd - pos)")
        if headerEnd - pos > 0 && headerEnd - pos <= 64 {
            hexDump(data, from: pos, count: headerEnd - pos)
        }
    }

    static func u32le(_ data: Data, at i: Int) -> UInt32 {
        UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
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

Dump2519Entries.run()
