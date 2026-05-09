import Foundation

func run() {
    guard CommandLine.arguments.count > 1 else { print("Usage: dump_earliest_clips <file.ptx>"); exit(1) }
    guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
        print("Cannot read file"); exit(1)
    }
    let n = raw.count
    print("File size: \(n)")

    // XOR decode into a new Data buffer (avoid [UInt8] copy for 30MB)
    let xv = raw[0x13]
    let mul: UInt16 = 11
    var delta: UInt8 = 0
    for i: UInt16 in 0...255 {
        if (i * mul) & 0xff == UInt16(xv) {
            delta = UInt8(truncatingIfNeeded: 256 &- Int(i))
            break
        }
    }
    var table = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }

    var d = raw
    d.withUnsafeMutableBytes { dst in
        raw.withUnsafeBytes { src in
            let dPtr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let sPtr = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let chunk = 4096
            var off = chunk
            while off < n {
                let xorByte = table[(off >> 12) & 0xff]
                if xorByte != 0 {
                    let end = min(off + chunk, n)
                    for j in off..<end { dPtr[j] = sPtr[j] ^ xorByte }
                }
                off += chunk
            }
        }
    }

    func u32(_ off: Int) -> UInt32 {
        guard off + 4 <= n else { return 0 }
        return d.withUnsafeBytes { p in
            let b = p.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return UInt32(b[off]) | UInt32(b[off+1]) << 8 | UInt32(b[off+2]) << 16 | UInt32(b[off+3]) << 24
        }
    }
    func u16(_ off: Int) -> UInt16 {
        guard off + 2 <= n else { return 0 }
        return d.withUnsafeBytes { p in
            let b = p.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return UInt16(b[off]) | UInt16(b[off+1]) << 8
        }
    }
    func byte(_ off: Int) -> UInt8 {
        guard off < n else { return 0 }
        return d.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self)[off] }
    }
    func hex(_ off: Int, _ count: Int) -> String {
        (0..<min(count, n - off)).map { String(format: "%02x", byte(off + $0)) }.joined(separator: " ")
    }

    // Scan blocks
    struct Block { let ct: UInt16; let off: Int; let size: Int }
    var blocks = [Block]()
    blocks.reserveCapacity(200_000)
    var i = 0x1f
    while i + 9 <= n {
        guard byte(i) == 0x5a else { i += 1; continue }
        let sz = Int(u32(i + 3))
        let ct = u16(i + 7)
        guard sz > 0, sz < 50_000_000, i + 9 + sz <= n else { i += 1; continue }
        blocks.append(Block(ct: ct, off: i + 9, size: sz))
        i += 1
    }
    print("Total blocks: \(blocks.count)")

    // Find audio 0x1054 container
    guard let container = blocks.filter({ $0.ct == 0x1054 }).sorted(by: { $0.off < $1.off }).first(where: { b in
        blocks.contains { $0.ct == 0x1052 && $0.off >= b.off && $0.off + $0.size <= b.off + b.size }
    }) else { print("No 0x1054 container"); return }

    let cStart = container.off, cEnd = container.off + container.size
    print("0x1054 container: \(cStart)..<\(cEnd) (size=\(container.size))")

    let refs = blocks.filter { $0.ct == 0x104f && $0.size >= 12 && $0.off >= cStart && $0.off + $0.size <= cEnd }
    print("0x104f count: \(refs.count)")

    // Sort by pos@7
    let sortedRefs = refs.sorted { u32($0.off + 7) < u32($1.off + 7) }

    // Show 20 earliest non-zero positions
    print("\n=== 20 earliest 0x104f blocks (by u32@off+7) ===")
    print("blockOff   sz    ci@2   @5          @6          @7          @8          @9          raw(16b)")
    var shown = 0
    for r in sortedRefs {
        let p7 = u32(r.off + 7)
        guard p7 > 0 else { continue }
        let ci = u16(r.off + 2)
        print(String(format: "%10d %-5d %-6d %-12u %-12u %-12u %-12u %-12u %@",
                     r.off, r.size, ci,
                     u32(r.off+5), u32(r.off+6), p7, u32(r.off+8), u32(r.off+9),
                     hex(r.off, 16)))
        shown += 1
        if shown >= 20 { break }
    }

    // Search for specific values in 0x104f block bytes
    print("\n=== Search: 86086, 86274, 172876704 ===")
    for target: UInt32 in [86086, 86274, 172876704] {
        var hits: [(blockOff: Int, byteOff: Int)] = []
        for r in refs {
            let maxBo = min(r.size - 4, 12)
            for bo in 3...maxBo {
                if u32(r.off + bo) == target { hits.append((r.off, bo)) }
            }
        }
        print("\n\(target) (0x\(String(target, radix:16))): \(hits.count) hits")
        for h in hits.prefix(5) {
            print(String(format: "  block@%d off+%d  raw: %@", h.blockOff, h.byteOff, hex(h.blockOff, 16)))
        }
    }
}
run()
