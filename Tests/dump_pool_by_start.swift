// Find compound pool entries by startSample value, and also dump what the
// synthesis fallback would produce for the 1-4 split tracks.
import Foundation

guard CommandLine.arguments.count > 1 else { print("Usage: \(CommandLine.arguments[0]) <file.ptx>"); exit(1) }
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let n = raw.count

let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
for i: UInt16 in 0...255 {
    if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
}
var table = [UInt8](repeating: 0, count: 256)
for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
var d = raw; let src = Array(raw)
d.withUnsafeMutableBytes { dst in
    let dp = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
    var off = 4096; while off < n {
        let xb = table[(off >> 12) & 0xff]
        if xb != 0 { let e = min(off+4096,n); for j in off..<e { dp[j]=src[j]^xb } }; off += 4096
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func u64le(_ i: Int) -> UInt64 { UInt64(u32le(i)) | UInt64(u32le(i+4))<<32 }
func readLE(_ i: Int, _ c: Int) -> UInt64 { var v: UInt64=0; for j in 0..<c { v |= UInt64(b(i+j))<<(j*8) }; return v }

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var idx = 0x1f; while idx+9 <= n {
    guard b(idx)==0x5a else { idx+=1; continue }
    let sz=Int(u32le(idx+3)); let ct=u16le(idx+7)
    guard sz>0, sz<50_000_000, idx+9+sz<=n else { idx+=1; continue }
    blocks.append(Blk(ct:ct, off:idx+9, sz:sz)); idx += 1
}

let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

struct PoolEntry { let idx: Int; let name: String; let start: Int64; let length: Int64 }
var pool: [PoolEntry] = []

for (i, parent) in all262b.enumerated() {
    let pEnd = parent.off + parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { continue }
    let pos = child.off
    guard pos+4 < n else { continue }
    let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { continue }
    guard let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8), !name.isEmpty else { continue }
    let tp = pos+4+nl; guard tp+5 <= n else { continue }
    let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
    let nLength  = Int((b(tp+2) & 0xf0) >> 4)
    let nStart   = Int((b(tp+3) & 0xf0) >> 4)
    guard tp+5+nSrcOff+nLength+nStart <= n else { continue }
    let lengthVal = readLE(tp+5+nSrcOff, nLength)
    guard lengthVal > 0, lengthVal < 10_000_000_000 else { continue }
    let startVal = readLE(tp+5+nSrcOff+nLength, nStart)
    pool.append(PoolEntry(idx: i, name: name, start: Int64(bitPattern: startVal), length: Int64(bitPattern: lengthVal)))
}

print("Compound pool entries with startSample near 188885472 (±500000):")
let target: Int64 = 188885472
for e in pool where abs(e.start - target) < 500000 {
    print("  [\(e.idx)] '\(e.name)' start=\(e.start) length=\(e.length) end=\(e.start+e.length)")
}

print("\nCompound pool entries at indices 70 and 183:")
for e in pool where e.idx == 70 || e.idx == 183 {
    print("  [\(e.idx)] '\(e.name)' start=\(e.start) length=\(e.length)")
}

// What would the synthesis fallback produce for the 1-4 split tracks?
// Synthesis: for each pool entry, find tracks with non-group clips in [start, end).
// The SYNTHESIS uses the compound pool startSample, not the track placement tl.
// Check if any synthesis entry would land around 188885472.
print("\nSynthesis candidates near tl=188885472 (pool entries whose range contains 188885472):")
for e in pool where e.start <= target && e.start + e.length > target {
    print("  [\(e.idx)] '\(e.name)' start=\(e.start) length=\(e.length) end=\(e.start+e.length)")
}
