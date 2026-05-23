import Foundation

guard CommandLine.arguments.count > 1 else { exit(1) }
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else { exit(1) }
let n = raw.count

let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
for i: UInt16 in 0...255 {
    if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
}
var table = [UInt8](repeating: 0, count: 256)
for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
var d = raw
d.withUnsafeMutableBytes { dst in
    raw.withUnsafeBytes { src in
        let dp = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let sp = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var off = 4096
        while off < n {
            let xb = table[(off >> 12) & 0xff]
            if xb != 0 { let e = min(off+4096,n); for j in off..<e { dp[j]=sp[j]^xb } }
            off += 4096
        }
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func hex(_ i: Int, _ c: Int) -> String { (0..<min(c,n-i)).map{String(format:"%02x",b(i+$0))}.joined(separator:" ") }
func str4(_ i: Int) -> String? {
    guard i+4 <= n else { return nil }
    let nl = Int(u32le(i)); guard nl > 0, nl <= 512, i+4+nl <= n else { return nil }
    return String(bytes: d[i+4..<i+4+nl], encoding: .utf8)
}

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
do {
    var i = 0x1f
    while i+9 <= n {
        guard b(i)==0x5a else { i+=1; continue }
        let sz=Int(u32le(i+3)); let ct=u16le(i+7)
        guard sz>0, sz<50_000_000, i+9+sz<=n else { i+=1; continue }
        blocks.append(Blk(ct:ct, off:i+9, sz:sz))
        i += 1
    }
}

// Find largest 0x262a
guard let pool262a = blocks.filter({ $0.ct == 0x262a }).sorted(by: { $0.sz > $1.sz }).first else {
    print("No 0x262a"); exit(0)
}
let pStart = pool262a.off, pEnd = pool262a.off + pool262a.sz
print("0x262a @\(pStart) sz=\(pool262a.sz)")

let inner262b = blocks.filter { $0.ct == 0x262b && $0.off >= pStart && $0.off+$0.sz <= pEnd }.sorted { $0.off < $1.off }
let inner2629 = blocks.filter { $0.ct == 0x2629 && $0.off >= pStart && $0.off+$0.sz <= pEnd }.sorted { $0.off < $1.off }
let innerRanges = (inner262b + inner2629).map { ($0.off, $0.off+$0.sz) }

func isInsideInner(_ bl: Blk) -> Bool {
    for (s, e) in innerRanges { if bl.off >= s && bl.off+bl.sz <= e { return true } }
    return false
}

// All block types directly in 0x262a
var typeCounts: [UInt16: Int] = [:]
for bl in blocks where bl.off >= pStart && bl.off+bl.sz <= pEnd && !isInsideInner(bl) {
    typeCounts[bl.ct, default: 0] += 1
}
print("Block types directly in 0x262a:")
for (ct, count) in typeCounts.sorted(by: { $0.key < $1.key }) {
    print(String(format: "  0x%04x × %d", ct, count))
}

// Show 0x0000 blocks
let direct0000 = blocks.filter {
    $0.ct == 0x0000 && $0.off >= pStart && $0.off+$0.sz <= pEnd && !isInsideInner($0)
}.sorted { $0.off < $1.off }
print("\n0x0000 blocks (total \(direct0000.count)):")
for bl in direct0000 {
    print("  @\(bl.off) sz=\(bl.sz): \(hex(bl.off, min(bl.sz, 32)))")
    if bl.sz >= 4 { print("  u32le[0]=\(u32le(bl.off))") }
}

// Show 0xff00 block
let directFF00 = blocks.filter {
    $0.ct == 0xff00 && $0.off >= pStart && $0.off+$0.sz <= pEnd && !isInsideInner($0)
}.sorted { $0.off < $1.off }
print("\n0xff00 blocks (total \(directFF00.count)):")
for bl in directFF00 {
    print("  @\(bl.off) sz=\(bl.sz): \(hex(bl.off, min(bl.sz, 32)))")
}

// Where are the 0x0000 blocks relative to 0x2629 parents?
print("\nPosition of 0x0000 relative to 0x2629:")
for (i, zero) in direct0000.prefix(12).enumerated() {
    // Find nearest 2629 before and after
    let before = inner2629.last { $0.off + $0.sz <= zero.off }
    let after  = inner2629.first { $0.off >= zero.off + zero.sz }
    print("  [0x0000 @\(zero.off)] after 2629@\(before?.off ?? -1) before 2629@\(after?.off ?? -1)")
}

// Check if 0x0000 blocks mark transitions between 0x262b pool and 0x2629 pool
print("\nLast 0x262b ends at: \(inner262b.last.map { $0.off + $0.sz } ?? -1)")
print("First 0x2629 starts at: \(inner2629.first?.off ?? -1)")
print("0x0000 blocks offsets: \(direct0000.prefix(5).map { $0.off })")
