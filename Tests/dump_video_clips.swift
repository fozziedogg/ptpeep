import Foundation

// Search for video clip names in the binary and show:
// 1. Which block type contains them
// 2. Surrounding byte context to reverse-engineer the clip list structure

let clipNames = [
    "Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole_81733583_00122907_00172823_en_2",
    "Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole_81733583_00122907_00172823_en_2-22",
    "Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole_81733583_00122907_00172823_en_2-16",
    "Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole_81733583_00122907_00172823_en_2-29",
]

@main
struct DumpVideoClips {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_video_clips <file.ptx>\n", stderr); exit(1)
        }
        let url  = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw  = try! Data(contentsOf: url)
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // Use the shortest name as needle (base name, unambiguous enough)
        let needle = Array("Something_Very_Bad_Is_Going_to_Happen_Season_1_Episode_2_BrideShaped_Hole".utf8)

        print("Searching \(data.count) bytes for video clip names...\n")

        // Find ALL occurrences in the file
        var hits: [Int] = []
        for i in 0 ..< (data.count - needle.count) {
            if (0..<needle.count).allSatisfy({ data[i + $0] == needle[$0] }) {
                hits.append(i)
            }
        }
        print("Found \(hits.count) occurrences of needle\n")

        for hit in hits {
            // Which block contains this hit?
            let containing = blocks.filter { $0.off <= hit && hit < $0.off + $0.size }
            let blockDesc = containing.map { String(format: "0x%04x @%d (size %d)", $0.ct, $0.off, $0.size) }.joined(separator: ", ")

            // Read the full null/non-printable-terminated string starting at hit
            var end = hit
            while end < data.count && data[end] >= 0x20 { end += 1 }
            let name = String(bytes: data[hit..<end], encoding: .utf8) ?? "???"

            // Show 32 bytes before the name start
            let pre = max(0, hit - 32)
            let preHex = (pre..<hit).map { String(format: "%02x", data[$0]) }.joined(separator: " ")

            // Show 64 bytes after name end
            let postEnd = min(data.count, end + 64)
            let postHex = (end..<postEnd).map { String(format: "%02x", data[$0]) }.joined(separator: " ")

            print("@\(hit)  block: \(blockDesc)")
            print("  name: \(name)")
            print("  pre:  \(preHex)")
            print("  post: \(postHex)")
            print()
        }

        // Also: list all block types that contain any of the 4 exact names
        print("═══ Block types containing clip names ═══")
        for clipName in clipNames {
            let cn = Array(clipName.utf8)
            for i in 0 ..< (data.count - cn.count) {
                guard (0..<cn.count).allSatisfy({ data[i + $0] == cn[$0] }) else { continue }
                // Check byte immediately after — must be non-printable (end of string)
                guard i + cn.count >= data.count || data[i + cn.count] < 0x20 else { continue }
                let containing = blocks.filter { $0.off <= i && i < $0.off + $0.size }
                for b in containing {
                    print(String(format: "  [\(clipName.suffix(10))] in block 0x%04x @%d", b.ct, b.off))
                }
            }
        }
    }

    struct Block { let ct: UInt16; let off: Int; let size: Int }

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
