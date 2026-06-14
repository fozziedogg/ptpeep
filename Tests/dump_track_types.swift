import Foundation

// Cross-reference known track types against raw binary data.
// Dumps full 0x1014 block content, full 0x2077 block content,
// and extended 0x2519 entry context for each known track.

let knownTypes: [(String, String)] = [
    ("PIX",                      "video/active"),
    ("GT PIX",                   "audio/stereo/INACTIVE"),
    ("SVB_BTS_InstagramMix",     "audio/stereo/active"),
    ("Printmaster",              "audio/stereo/active"),
    ("Master Bus",               "aux/stereo/active"),
    ("ƒ DME",                    "folder/active"),
    ("SVB_102_2.0 DIA_Final_01", "audio/stereo/active/inFolder"),
    ("SVB_102_2.0 MUS_Final_01", "audio/stereo/active/inFolder"),
    ("SVB_102_2.0 SFX_Final_01", "audio/stereo/active/inFolder"),
    ("vDME",                     "VCA/active"),
    ("Haley 1",                  "audio/mono/active"),
    ("Haley 2",                  "audio/mono/active"),
    ("Haley 1.dup1",             "audio/mono/INACTIVE/hidden"),
    ("Haley 2.dup1",             "audio/mono/INACTIVE/hidden"),
    ("PART ONE.dup1",            "audio/mono/INACTIVE"),
    ("Aux 1",                    "aux/active"),
]

@main
struct DumpTrackTypes {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_track_types <file.ptx>\n", stderr); exit(1)
        }
        let url  = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw  = try! Data(contentsOf: url)
        let data = xorDecode(raw)!
        let blocks = scanBlocks(data)

        // ── 1. Full 0x1014 blocks ──────────────────────────────────────────
        print("═══ 0x1014 blocks (track entries) ═══")
        let track1014 = blocks.filter { $0.ct == 0x1014 }
        for b in track1014 {
            let pos = b.off + 2   // skip 2-byte header
            guard let nl = u32LE(data, at: pos), nl >= 1, nl <= 256 else { continue }
            let nameEnd = pos + 4 + Int(nl)
            guard nameEnd <= data.count,
                  let name = String(bytes: data[pos+4 ..< nameEnd], encoding: .utf8) else { continue }
            let type = knownTypes.first(where: { $0.0 == name })?.1 ?? "?"
            // dump all bytes in the block
            let allHex = (0..<b.size).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  [\(name)] [\(type)]")
            print("    size=\(b.size)  hex: \(allHex)")
        }

        // ── 2. 0x2077 blocks ──────────────────────────────────────────────
        print("\n═══ 0x2077 blocks ═══")
        for b in blocks.filter({ $0.ct == 0x2077 }) {
            let allHex = (0..<b.size).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size): \(allHex)")
        }

        // ── 3. 0x1017 blocks ──────────────────────────────────────────────
        print("\n═══ 0x1017 blocks ═══")
        for b in blocks.filter({ $0.ct == 0x1017 }) {
            let allHex = (0..<b.size).map { String(format: "%02x", data[b.off + $0]) }.joined(separator: " ")
            print("  @\(b.off) size=\(b.size): \(allHex)")
        }

        // ── 4. Extended 0x2519 entries for each known track ───────────────
        print("\n═══ 0x2519 entries (64 bytes context each) ═══")
        guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else {
            print("No 0x2519"); return
        }
        for (trackName, trackType) in knownTypes {
            let needle = Array(trackName.utf8)
            // find all occurrences within 0x2519
            var hits: [Int] = []
            for i in b2519.off ..< (b2519.off + b2519.size - needle.count) {
                if (0..<needle.count).allSatisfy({ data[i + $0] == needle[$0] }) {
                    hits.append(i)
                }
            }
            print("\n  [\(trackName)] [\(trackType)]  (\(hits.count) hits)")
            for hit in hits.prefix(2) {
                // show 8 bytes before name start, then up to 80 bytes after name end
                let nameStart = hit
                let nameEnd   = hit + needle.count
                let from      = max(b2519.off, nameStart - 8)
                let to        = min(b2519.off + b2519.size, nameEnd + 80)
                let bytes     = (from..<to)
                let offset    = nameStart - from
                var hexParts: [String] = []
                for (i, pos) in bytes.enumerated() {
                    let b = String(format: "%02x", data[pos])
                    if i == offset { hexParts.append("[\(b)") }
                    else if i == offset + needle.count - 1 { hexParts.append("\(b)]") }
                    else { hexParts.append(b) }
                }
                print("    @\(hit): \(hexParts.joined(separator: " "))")
            }
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────────

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
        var d = raw; for i in 0..<raw.count { d[i] = raw[i] ^ t[(i >> 12) & 0xff] }
        return d
    }
}
