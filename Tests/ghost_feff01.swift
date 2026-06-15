import Foundation

// Check if bytes[16-18] == fe ff 01 is a reliable ghost filter.
// Also identify what tracks the 2 ghost blocks with feff00 are on.

func run() {
    guard CommandLine.arguments.count > 1 else { print("Usage: ghost_feff01 <file.ptx>"); exit(1) }
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

    // Find 0x1052 sections and their names
    guard let container1054 = blocks.filter({ $0.ct == 0x1054 }).sorted(by: { $0.off < $1.off }).first(where: { b in
        blocks.contains { $0.ct == 0x1052 && $0.off >= b.off && $0.off + $0.size <= b.off + b.size }
    }) else { print("No 0x1054 container"); return }

    let cStart = container1054.off
    let cEnd   = container1054.off + container1054.size

    let sections1052 = blocks.filter { $0.ct == 0x1052 && $0.off >= cStart && $0.off + $0.size <= cEnd }
        .sorted { $0.off < $1.off }

    // Build section name → range
    var sectionNames: [(name: String, start: Int, end: Int)] = []
    for s in sections1052 {
        let p = s.off
        let nl = Int(u32le(p))
        guard nl >= 1, nl <= 256, p + 4 + nl <= data.count else { continue }
        let nameSlice = data[(p+4)..<(p+4+nl)]
        guard let name = String(bytes: nameSlice, encoding: .utf8) else { continue }
        sectionNames.append((name, s.off, s.off + s.size))
    }

    func findSection(_ off: Int) -> String {
        // Find innermost containing section
        let candidates = sectionNames.filter { $0.start <= off && off < $0.end }
        return candidates.last?.name ?? "<unknown>"
    }

    let refs104f = blocks.filter { $0.ct == 0x104f && $0.size >= 19 && $0.off >= cStart && $0.off + $0.size <= cEnd }
        .sorted { $0.off < $1.off }

    let ghostPos: Int64 = 172_876_704

    // Count blocks where bytes[16-18] == fe ff 01
    var feff01count = 0
    var feff01ghostCount = 0
    var feff01nonGhostCount = 0

    print("=== All 0x104f blocks with bytes[16-18] == fe ff 01 ===")
    for r in refs104f {
        guard data[r.off + 16] == 0xfe, data[r.off + 17] == 0xff, data[r.off + 18] == 0x01 else { continue }
        feff01count += 1
        let pos = u32le(r.off + 7)
        let track = findSection(r.off)
        let clipIdx = u16le(r.off + 2)
        if pos == ghostPos {
            feff01ghostCount += 1
        } else {
            feff01nonGhostCount += 1
            print(String(format: "  NON-GHOST @%d track='%@' clipIdx=%d pos=%lld  %@",
                         r.off, track, clipIdx, pos, hex(r.off, min(r.size, 20))))
        }
    }
    print("Total feff01: \(feff01count) (ghost=\(feff01ghostCount) nonGhost=\(feff01nonGhostCount))")

    // Now find the 2 ghost blocks with feff00 and identify their tracks
    print("\n=== Ghost blocks with bytes[16-18] == fe ff 00 (not the feff01 type) ===")
    for r in refs104f {
        let pos = u32le(r.off + 7)
        guard pos == ghostPos else { continue }
        guard !(data[r.off + 16] == 0xfe && data[r.off + 17] == 0xff && data[r.off + 18] == 0x01) else { continue }
        let track = findSection(r.off)
        let clipIdx = u16le(r.off + 2)
        print(String(format: "  @%d track='%@' clipIdx=%d  %@", r.off, track, clipIdx, hex(r.off, r.size)))
    }

    // What is the clip pool name for clipIdx 9390 and 9391?
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
    print("\n=== Clip pool entries 398-403 ===")
    var clipIdx2 = 0
    for block in blocks where block.ct == 0x2628 {
        guard isInClipPool(block) else { continue }
        if clipIdx2 >= 398 && clipIdx2 <= 403 {
            let pos = block.off
            let nl = Int(u32le(pos))
            guard nl >= 1, nl <= 512, pos + 4 + nl <= data.count else { clipIdx2 += 1; continue }
            let nameSlice = data[(pos+4)..<(pos+4+nl)]
            let name = String(bytes: nameSlice, encoding: .utf8) ?? "<invalid>"
            print("  Clip[\(clipIdx2)]: '\(name)' sz=\(block.size)")
        }
        if clipIdx2 >= 9388 && clipIdx2 <= 9393 {
            let pos = block.off
            let nl = Int(u32le(pos))
            guard nl >= 1, nl <= 512, pos + 4 + nl <= data.count else { clipIdx2 += 1; continue }
            let nameSlice = data[(pos+4)..<(pos+4+nl)]
            let name = String(bytes: nameSlice, encoding: .utf8) ?? "<invalid>"
            print("  Clip[\(clipIdx2)]: '\(name)' sz=\(block.size)")
        }
        clipIdx2 += 1
    }

    // Summary: what would be filtered by feff01?
    print("\n=== Summary ===")
    let total104f = refs104f.count
    let feff01filtered = refs104f.filter {
        $0.size >= 19 && data[$0.off + 16] == 0xfe && data[$0.off + 17] == 0xff && data[$0.off + 18] == 0x01
    }.count
    print("Total 0x104f (main container, sz>=19): \(total104f)")
    print("Would filter (feff01): \(feff01filtered)")
    print("Would keep: \(total104f - feff01filtered)")
}
run()
