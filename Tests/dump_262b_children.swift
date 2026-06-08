import Foundation

// For each 0x262b parent, count ALL 0x2628 children and show their full data.
// Goal: determine if compound pool parents have >1 child (first=identity, rest=constituents).

guard CommandLine.arguments.count > 1 else { print("Usage: dump_262b_children <file.ptx>"); exit(1) }
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
    guard i+4<=n else { return nil }
    let nl=Int(u32le(i)); guard nl>0,nl<=512,i+4+nl<=n else { return nil }
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

let parents262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628     = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

print("0x262b parents: \(parents262b.count)")

var multipleCount = 0
for (pIdx, parent) in parents262b.enumerated() {
    let pEnd = parent.off + parent.sz
    // All 0x2628 blocks strictly within this parent
    var lo = 0, hi = all2628.count
    while lo < hi { let m=(lo+hi)/2; if all2628[m].off < parent.off {lo=m+1} else {hi=m} }
    var children: [Blk] = []
    var j = lo
    while j < all2628.count && all2628[j].off < pEnd {
        if all2628[j].off + all2628[j].sz <= pEnd { children.append(all2628[j]) }
        j += 1
    }

    if children.count > 1 { multipleCount += 1 }
    print("\n=== pool[\(pIdx)] 0x262b @\(parent.off) sz=\(parent.sz) — \(children.count) child(ren) ===")
    for (ci, child) in children.enumerated() {
        let nm = str4(child.off) ?? "<no_name>"
        print("  child[\(ci)] @\(child.off) sz=\(child.sz) name='\(nm)'")
        print("  raw: \(hex(child.off, min(child.sz, 64)))")
        // Three-point section
        guard child.sz >= 4 else { continue }
        let nl = Int(u32le(child.off)); guard nl > 0, nl <= 512, child.off+4+nl <= n else { continue }
        let tp = child.off + 4 + nl
        guard tp+5 <= n else { continue }
        let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
        let nLength = Int((b(tp+2) & 0xf0) >> 4)
        let nStart  = Int((b(tp+3) & 0xf0) >> 4)
        var vp = tp + 5
        let srcOff  = (0..<nSrcOff).reduce(UInt64(0)) { acc, i in acc | (UInt64(b(vp+i)) << (i*8)) }; vp += nSrcOff
        let length  = (0..<nLength).reduce(UInt64(0)) { acc, i in acc | (UInt64(b(vp+i)) << (i*8)) }; vp += nLength
        let start   = (0..<nStart ).reduce(UInt64(0)) { acc, i in acc | (UInt64(b(vp+i)) << (i*8)) }
        let fileIdx = child.sz >= 2 ? Int(u16le(child.off + child.sz - 2)) : -1
        print("  → srcOff=\(srcOff) length=\(length) start=\(start) fileIdx=\(fileIdx)")
    }
}
print("\n=== Summary: \(multipleCount)/\(parents262b.count) parents have >1 child ===")
