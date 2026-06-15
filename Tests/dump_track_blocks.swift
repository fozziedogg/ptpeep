import Foundation

// Dumps the full 0x2519 block (track list) to map out every entry's structure
// and confirm the hidden-track indicator.

@main
struct DumpTrackBlocks {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_track_blocks <file.ptx>\n", stderr); exit(1)
        }
        let url  = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw  = try! Data(contentsOf: url)
        let data = PTXBlockDecoder.xorDecode(raw)!
        let be   = PTXBlockDecoder.isBigEndian(data)
        let blocks = PTXBlockDecoder.scanBlocks(data: data, bigEndian: be)

        // 1. Full 0x2519 block (the one track-list block)
        guard let b2519 = blocks.first(where: { $0.contentType == 0x2519 }) else {
            print("No 0x2519 block found"); return
        }
        print("0x2519 block: dataOffset=\(b2519.dataOffset) size=\(b2519.dataSize)")
        print("Full hex dump:")
        let allBytes = (0..<b2519.dataSize).map { String(format: "%02x", data[b2519.dataOffset + $0]) }
        for row in stride(from: 0, to: allBytes.count, by: 16) {
            print(String(format: "  %04x  ", row) + allBytes[row..<min(row+16, allBytes.count)].joined(separator: " "))
        }

        // 2. Walk 0x2519 block entries, looking for the known structure:
        //    [4-byte leading][u32 nameLen][name][6 zeros][u32 marker=42][8-byte UUID][4-byte field][...]
        print("\n\nParsed 0x2519 entries:")
        let knownHidden: Set<String> = ["Haley 1.dup1", "Haley 2.dup1"]
        var pos = b2519.dataOffset
        let end = b2519.dataOffset + b2519.dataSize
        var entryCount = 0
        while pos + 8 < end {
            // Try to read nameLen at current position
            let nl = Int(PTXBlockDecoder.u32(data, at: pos, be: false))
            if nl < 1 || nl > 64 || pos + 4 + nl > end {
                pos += 1; continue
            }
            let nameSlice = data[pos+4 ..< pos+4+nl]
            guard nameSlice.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                  let name = String(bytes: nameSlice, encoding: .utf8) else {
                pos += 1; continue
            }
            // Found a plausible name. Read trailing structure.
            let afterName = pos + 4 + nl
            // Expect: 6 zeros, 0x2a 00 00 00, 8-byte UUID, 4-byte field
            let structEnd = afterName + 6 + 4 + 8 + 4
            guard structEnd <= end else { pos += 1; continue }
            let sixZeros = (0..<6).allSatisfy { data[afterName + $0] == 0 }
            let marker   = PTXBlockDecoder.u32(data, at: afterName + 6, be: false)
            guard sixZeros, marker == 42 else { pos += 1; continue }
            // UUID
            let uuidBytes = (0..<8).map { String(format: "%02x", data[afterName + 10 + $0]) }.joined(separator: " ")
            // Post-UUID 4-byte field
            let field0 = data[afterName + 18]
            let field1 = data[afterName + 19]
            let field2 = data[afterName + 20]
            let field3 = data[afterName + 21]
            let hidden = (field0 == 0 && field1 == 0 && field2 == 0 && field3 == 0)
            let hiddenTag = knownHidden.contains(name) ? " ← KNOWN HIDDEN" : (hidden ? " ← zero-field" : "")
            print(String(format: "  [%2d] %-30s  field=%02x %02x %02x %02x  hidden=%@%@",
                         entryCount, name, field0, field1, field2, field3,
                         hidden ? "YES" : "no ", hiddenTag))
            entryCount += 1
            pos = afterName + 22   // advance past this entry
        }
    }
}
