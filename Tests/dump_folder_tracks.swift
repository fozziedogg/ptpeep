import Foundation

// Find folder track indicators by searching for known name bytes in the decoded data,
// then dumping raw context around each occurrence.

@main
struct DumpFolderTracks {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_folder_tracks <file.ptx>\n", stderr); exit(1)
        }
        let url  = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw  = try! Data(contentsOf: url)
        let data = xorDecode(raw)!

        // 1. Show what bytes "ƒ DME" and the SVB tracks encode to
        let folderName = "ƒ DME"
        let child1     = "SVB_102_2.0 DIA_Final_01"
        let child2     = "SVB_102_2.0 MUS_Final_01"
        let child3     = "SVB_102_2.0 SFX_Final_01"

        for name in [folderName, child1, child2, child3] {
            let utf8 = Array(name.utf8)
            print("UTF-8 of \"\(name)\": \(utf8.map { String(format: "%02x", $0) }.joined(separator: " "))  (\(utf8.count) bytes)")
        }
        print()

        // 2. Search the decoded data for each name's UTF-8 bytes and dump 80 bytes of context
        for name in [folderName, child1, child2, child3] {
            let needle = Array(name.utf8)
            var hits: [Int] = []
            for i in 0...(data.count - needle.count) {
                if (0..<needle.count).allSatisfy({ data[i + $0] == needle[$0] }) {
                    hits.append(i)
                }
            }
            print("═══ \"\(name)\" (\(hits.count) hits) ═══")
            for hit in hits.prefix(4) {
                // Show 8 bytes before (likely nameLen prefix) and 64 bytes after name end
                let before = max(0, hit - 8)
                let after  = min(data.count, hit + needle.count + 64)
                let bytes  = (before..<after).map { String(format: "%02x", data[$0]) }
                let nameStartIdx = hit - before   // index within bytes[] where name begins
                // Print with marker showing name position
                let hex = bytes.enumerated().map { i, b -> String in
                    if i == nameStartIdx { return "[\(b)" }
                    if i == nameStartIdx + needle.count - 1 { return "\(b)]" }
                    return b
                }.joined(separator: " ")
                print("  @\(hit) (block-rel \(hit - 321)): \(hex)")
            }
            print()
        }

        // 3. Dump the 0x2519 flat section with high-byte names allowed
        guard let b = findBlock(data: data, type: 0x2519) else {
            print("No 0x2519 block"); return
        }
        print("─── 0x2519 entries (high-byte names allowed) ───")
        var pos = b.0
        let end = b.0 + b.1
        var entryNum = 0
        while pos + 4 < end {
            let nl = Int(u32LE(data, at: pos))
            guard nl >= 1, nl <= 128, pos + 4 + nl + 19 <= end else { pos += 1; continue }
            let nameSlice = data[pos+4 ..< pos+4+nl]
            // Allow all bytes >= 0x20 (including high bytes for non-ASCII names)
            guard nameSlice.allSatisfy({ $0 >= 0x20 }),
                  let name = String(bytes: nameSlice, encoding: .utf8) else { pos += 1; continue }
            let nameEnd = pos + 4 + nl
            let sixZeros = (0..<6).allSatisfy { data[nameEnd + $0] == 0 }
            let marker   = u32LE(data, at: nameEnd + 6)
            guard sixZeros, marker == 42 else { pos += 1; continue }
            let displayIndex = data[nameEnd + 18]
            // 4 bytes immediately after displayIndex
            let post = (nameEnd+19..<min(nameEnd+27, end)).map { String(format:"%02x", data[$0]) }.joined(separator:" ")
            print(String(format: "  [%2d] @%d  disp=0x%02x  post=\(post)  \"\(name)\"",
                         entryNum, pos, displayIndex))
            entryNum += 1
            pos = nameEnd + 19
        }
        print("Total: \(entryNum) entries")
    }

    static func u32LE(_ d: Data, at i: Int) -> UInt32 {
        guard i + 4 <= d.count else { return 0 }
        return UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
    }

    static func findBlock(data: Data, type: UInt16) -> (Int, Int)? {
        var i = 0x1f
        while i + 9 <= data.count {
            guard data[i] == 0x5a else { i += 1; continue }
            let size = Int(u32LE(data, at: i + 3))
            let ct   = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
            guard size > 0, size < 50_000_000, i + 9 + size <= data.count else { i += 1; continue }
            if ct == type { return (i + 9, size) }
            i += 1
        }
        return nil
    }

    static func xorDecode(_ raw: Data) -> Data? {
        guard raw.count > 0x14 else { return nil }
        let fileType = raw[0x12]; let xorValue = raw[0x13]
        guard fileType == 0x05 else { return nil }
        let mul: UInt16 = 11; var delta: UInt8 = 0
        for i: UInt16 in 0...255 {
            if (i * mul) & 0xff == UInt16(xorValue) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
        }
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
        var decoded = raw
        for i in 0..<raw.count { decoded[i] = raw[i] ^ table[(i >> 12) & 0xff] }
        return decoded
    }
}
