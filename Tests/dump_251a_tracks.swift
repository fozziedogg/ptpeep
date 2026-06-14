import Foundation

// Dump all 0x251a track entries from the 0x2519 container for Ninvingajuliat session.
// Shows: name, type code, hidden, inactive, folder flag — in PT mixer order.

struct Dump251a {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_251a_tracks <file.ptx>\n", stderr); exit(1)
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

        print("0x2519 @\(b2519.off) size=\(b2519.size)")
        print("0x251a sub-blocks: \(subBlocks.count)\n")
        print("#     type    off     hid  ina  fld  name")
        print(String(repeating: "-", count: 80))

        var typeNames = [UInt16: String]()
        typeNames[0x00] = "audio"
        typeNames[0x02] = "aux"
        typeNames[0x08] = "video"
        typeNames[0x09] = "VCA"
        typeNames[0x0b] = "folder"

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

            // Flag at nameEnd+53
            let folderFlagOff = nameEnd + 53
            let folderFlag = folderFlagOff < sub.off + sub.size && data[folderFlagOff] != 0

            // Hidden/inactive
            let b2Off = p + 63 + nameLen
            let b3Off = p + 64 + nameLen
            let hidden   = b2Off < sub.off + sub.size && data[b2Off] == 0
            let inactive = b3Off < sub.off + sub.size && data[b3Off] == 0

            let typeName = typeNames[typeCode] ?? String(format: "0x%04x", typeCode)
            let hidStr  = hidden   ? "HID" : ""
            let inaStr  = inactive ? "INA" : ""
            let fldStr  = folderFlag ? "FLD" : ""

            let line = "\(i)".padding(toLength: 5, withPad: " ", startingAt: 0)
                     + typeName.padding(toLength: 8, withPad: " ", startingAt: 0)
                     + "\(sub.off)".padding(toLength: 8, withPad: " ", startingAt: 0)
                     + hidStr.padding(toLength: 5, withPad: " ", startingAt: 0)
                     + inaStr.padding(toLength: 5, withPad: " ", startingAt: 0)
                     + fldStr.padding(toLength: 5, withPad: " ", startingAt: 0)
                     + name
            print(line)
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

Dump251a.run()
