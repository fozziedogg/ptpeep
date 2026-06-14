import Foundation

// Full dump of ghost vs normal 0x104f blocks to find reliable filter.
// Ghost: 00 00 90 01 00 00 00 a0 e3 4d 0a 00 00 00 00 03 fe ff 01 00 00 00 ff ff ff ff ff ff ff ff 00 00 ...

func run() {
    guard CommandLine.arguments.count > 1 else { print("Usage: ghost_full <file.ptx>"); exit(1) }
    let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    var t = [UInt8](repeating: 0, count: 256)
    let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
    for i: UInt16 in 0...255 { if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break } }
    for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var data = raw; for i in 0..<raw.count { data[i] = raw[i] ^ t[(i >> 12) & 0xff] }

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

    guard let container1054 = blocks.filter({ $0.ct == 0x1054 }).sorted(by: { $0.off < $1.off }).first(where: { b in
        blocks.contains { $0.ct == 0x1052 && $0.off >= b.off && $0.off + $0.size <= b.off + b.size }
    }) else { print("No 0x1054 container"); return }

    let cStart = container1054.off
    let cEnd   = container1054.off + container1054.size

    let refs104f = blocks.filter { $0.ct == 0x104f && $0.size >= 16 && $0.off >= cStart && $0.off + $0.size <= cEnd }
        .sorted { $0.off < $1.off }

    let ghostPos: Int64 = 172_876_704

    // Full bytes for all ghost blocks
    print("=== GHOST BLOCKS (full content) ===")
    for r in refs104f.filter({ u32le($0.off + 7) == ghostPos }) {
        print("  sz=\(r.size): \(hex(r.off, r.size))")
    }

    // Full bytes for a sample of normal blocks of same sizes
    print("\n=== NORMAL BLOCKS sampled (sz=37) ===")
    var shown = 0
    for r in refs104f where r.size == 37 && u32le(r.off + 7) != ghostPos && u32le(r.off + 7) > 0 && shown < 20 {
        print("  sz=\(r.size): \(hex(r.off, r.size))")
        shown += 1
    }

    // Check distribution of bytes 16-22 for sz=37 blocks
    print("\n=== byte[16..17] distribution for sz=37 blocks ===")
    var dist = [(b16b17: String, isGhost: Bool, count: Int)]()
    var distMap = [String: (ghost: Int, normal: Int)]()
    for r in refs104f where r.size == 37 {
        let pos = u32le(r.off + 7)
        let b16b17 = String(format: "%02x%02x", data[r.off + 16], data[r.off + 17])
        if pos == ghostPos {
            distMap[b16b17, default: (0,0)].ghost += 1
        } else if pos > 0 {
            distMap[b16b17, default: (0,0)].normal += 1
        }
    }
    for (k, v) in distMap.sorted(by: { $0.key < $1.key }) {
        print("  \(k): ghost=\(v.ghost) normal=\(v.normal)")
    }

    // Check bytes 23-28 for 0xff pattern
    print("\n=== Ghost: bytes 23-28 all 0xff? ===")
    for r in refs104f.filter({ u32le($0.off + 7) == ghostPos }) {
        guard r.size >= 29 else { print("  too small"); continue }
        let allFF = (23...28).allSatisfy { data[r.off + $0] == 0xff }
        print("  sz=\(r.size) bytes[23-28]=\(hex(r.off+23, 6)) allFF=\(allFF)")
    }

    print("\n=== Normal sz=37: how many have bytes 23-28 all 0xff? ===")
    var allffCount = 0; var notAllffCount = 0
    for r in refs104f where r.size == 37 && u32le(r.off + 7) > 0 && u32le(r.off + 7) != ghostPos {
        let allFF = (23...28).allSatisfy { data[r.off + $0] == 0xff }
        if allFF { allffCount += 1 } else { notAllffCount += 1 }
    }
    print("  allFF=\(allffCount) notAllFF=\(notAllffCount)")

    // Look at clip pool entry 400 (the ghost clipIdx)
    print("\n=== Clip pool entry 400 from 0x2628 in 0x2629 ===")
    let clipParentRanges: [(Int, Int)] = blocks
        .filter { $0.ct == 0x2629 }
        .map { ($0.off, $0.off + $0.size) }
        .sorted { $0.0 < $1.0 }

    func isInClipPool(_ block: (ct: UInt16, off: Int, size: Int)) -> Bool {
        var lo = 0, hi = clipParentRanges.count
        while lo < hi { let mid = (lo + hi) / 2; if clipParentRanges[mid].0 <= block.off { lo = mid + 1 } else { hi = mid } }
        let idx = lo - 1
        guard idx >= 0 else { return false }
        return block.off + block.size <= clipParentRanges[idx].1
    }

    var clipIdx = 0
    for block in blocks where block.ct == 0x2628 {
        guard isInClipPool(block) else { continue }
        let pos = block.off
        let nl = Int(UInt32(data[pos]) | UInt32(data[pos+1]) << 8 | UInt32(data[pos+2]) << 16 | UInt32(data[pos+3]) << 24)
        guard nl >= 1, nl <= 512, pos + 4 + nl <= data.count else { clipIdx += 1; continue }
        if clipIdx == 400 {
            let nameSlice = data[(pos+4)..<(pos+4+nl)]
            let name = String(bytes: nameSlice, encoding: .utf8) ?? "<invalid>"
            print("  Clip 400: name='\(name)' sz=\(block.size)")
            print("  Full block: \(hex(pos, min(block.size, 64)))")
            break
        }
        clipIdx += 1
    }
}
run()
