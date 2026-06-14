import Foundation

// Investigate byte layout of 0x104f blocks:
// Compare ghost clips (position=172876704) vs normal clips.
// Ghost bytes: 00 00 90 01 00 00 00 a0 e3 4d 0a 00 00 00 00 03
// Hypothesis: byte +15 == 0x03 marks a clip that should be hidden/filtered.

func run() {
    guard CommandLine.arguments.count > 1 else { print("Usage: ghost_flag <file.ptx>"); exit(1) }
    let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    var t = [UInt8](repeating: 0, count: 256)
    let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
    for i: UInt16 in 0...255 { if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break } }
    for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var data = raw; for i in 0..<raw.count { data[i] = raw[i] ^ t[(i >> 12) & 0xff] }

    // Scan all blocks
    var blocks = [(ct: UInt16, off: Int, size: Int)]()
    var i = 0x1f
    while i + 9 <= data.count {
        guard data[i] == 0x5a else { i += 1; continue }
        let sz = Int(UInt32(data[i+3]) | UInt32(data[i+4]) << 8 | UInt32(data[i+5]) << 16 | UInt32(data[i+6]) << 24)
        let ct = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
        guard sz > 0, sz < 50_000_000, i + 9 + sz <= data.count else { i += 1; continue }
        blocks.append((ct, i + 9, sz))
        i += 1
    }

    func u16le(_ off: Int) -> Int { Int(data[off]) | Int(data[off+1]) << 8 }
    func u32le(_ off: Int) -> Int64 { Int64(data[off]) | Int64(data[off+1]) << 8 | Int64(data[off+2]) << 16 | Int64(data[off+3]) << 24 }
    func hex(_ off: Int, _ n: Int) -> String {
        (0..<min(n, data.count - off)).map { String(format: "%02x", data[off + $0]) }.joined(separator: " ")
    }

    // Find 0x1054 main container
    guard let container1054 = blocks.filter({ $0.ct == 0x1054 }).sorted(by: { $0.off < $1.off }).first(where: { b in
        blocks.contains { $0.ct == 0x1052 && $0.off >= b.off && $0.off + $0.size <= b.off + b.size }
    }) else { print("No 0x1054 container found"); return }

    let cStart = container1054.off
    let cEnd   = container1054.off + container1054.size

    // All 0x104f blocks in main container
    let refs104f = blocks.filter { $0.ct == 0x104f && $0.size >= 16 && $0.off >= cStart && $0.off + $0.size <= cEnd }
        .sorted { $0.off < $1.off }

    let ghostPos: Int64 = 172_876_704

    // Tally byte[0], byte[1], byte[15] for ghost vs non-ghost
    var ghostBytes0  = [UInt8: Int]()
    var ghostBytes1  = [UInt8: Int]()
    var ghostBytes15 = [UInt8: Int]()
    var normalBytes0  = [UInt8: Int]()
    var normalBytes1  = [UInt8: Int]()
    var normalBytes15 = [UInt8: Int]()

    var ghostCount = 0; var normalCount = 0

    for r in refs104f {
        let p    = r.off
        let pos  = u32le(p + 7)
        let b0   = data[p]
        let b1   = data[p + 1]
        // byte +15 if block is large enough
        let b15  = r.size >= 16 ? data[p + 15] : 0xff

        if pos == ghostPos {
            ghostCount += 1
            ghostBytes0[b0, default: 0] += 1
            ghostBytes1[b1, default: 0] += 1
            ghostBytes15[b15, default: 0] += 1
        } else if pos > 0 {
            normalCount += 1
            normalBytes0[b0, default: 0] += 1
            normalBytes1[b1, default: 0] += 1
            normalBytes15[b15, default: 0] += 1
        }
    }

    print("Ghost clips (pos=172876704): \(ghostCount)")
    print("  byte[0]:  \(ghostBytes0.sorted(by:{$0.key<$1.key}).map{String(format:"%02x=%d",$0.key,$0.value)}.joined(separator:", "))")
    print("  byte[1]:  \(ghostBytes1.sorted(by:{$0.key<$1.key}).map{String(format:"%02x=%d",$0.key,$0.value)}.joined(separator:", "))")
    print("  byte[15]: \(ghostBytes15.sorted(by:{$0.key<$1.key}).map{String(format:"%02x=%d",$0.key,$0.value)}.joined(separator:", "))")

    print("\nNormal clips: \(normalCount)")
    print("  byte[0]:  \(normalBytes0.sorted(by:{$0.key<$1.key}).map{String(format:"%02x=%d",$0.key,$0.value)}.joined(separator:", "))")
    print("  byte[1]:  \(normalBytes1.sorted(by:{$0.key<$1.key}).map{String(format:"%02x=%d",$0.key,$0.value)}.joined(separator:", "))")
    print("  byte[15]: \(normalBytes15.sorted(by:{$0.key<$1.key}).map{String(format:"%02x=%d",$0.key,$0.value)}.joined(separator:", "))")

    // Also show all unique 0x104f content patterns for ghost blocks
    print("\n--- Ghost 0x104f full content (first 3) ---")
    var shown = 0
    for r in refs104f {
        let pos = u32le(r.off + 7)
        guard pos == ghostPos, shown < 3 else { continue }
        print("  @\(r.off) sz=\(r.size): \(hex(r.off, min(r.size, 32)))")
        shown += 1
    }

    // Show all unique byte-15 values with sample counts
    print("\n--- byte[15] distribution across ALL 0x104f blocks in main container ---")
    var all15 = [UInt8: Int]()
    for r in refs104f where r.size >= 16 {
        all15[data[r.off + 15], default: 0] += 1
    }
    for (k, v) in all15.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  %02x  = %d blocks", k, v))
    }

    // Check if all byte[15]==0x03 blocks are at ghost position
    print("\n--- All blocks with byte[15]==0x03 ---")
    var b03count = 0
    for r in refs104f where r.size >= 16 && data[r.off + 15] == 0x03 {
        let pos = u32le(r.off + 7)
        let clipIdx = u16le(r.off + 2)
        if b03count < 20 {
            print(String(format: "  @%d clipIdx=%d pos=%d (%lld)  %@", r.off, clipIdx, pos, pos, hex(r.off, min(r.size, 20))))
        }
        b03count += 1
    }
    print("  Total byte[15]==0x03: \(b03count)")

    // Check how many non-ghost blocks have byte[15]==0x03
    let nonGhostB03 = refs104f.filter { r in
        guard r.size >= 16 else { return false }
        let pos = u32le(r.off + 7)
        return data[r.off + 15] == 0x03 && pos != ghostPos && pos > 0
    }
    print("  Non-ghost blocks with byte[15]==0x03: \(nonGhostB03.count)")
    for r in nonGhostB03.prefix(5) {
        let pos = u32le(r.off + 7)
        let clipIdx = u16le(r.off + 2)
        print(String(format: "    @%d clipIdx=%d pos=%lld  %@", r.off, clipIdx, pos, hex(r.off, min(r.size, 20))))
    }
}
run()
