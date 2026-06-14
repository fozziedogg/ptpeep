// Dump raw bytes of 0x104f blocks inside each sentinel 0x1052,
// plus count 0x2629 blocks and list combined pool entries.
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
func hex(_ i: Int, _ c: Int) -> String { (0..<min(c,max(0,n-i))).map { String(format:"%02x",b(i+$0)) }.joined(separator:" ") }

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var ii = 0x1f; while ii+9 <= n {
    guard b(ii)==0x5a else { ii+=1; continue }
    let sz=Int(u32le(ii+3)); let ct=u16le(ii+7)
    guard sz>0, sz<50_000_000, ii+9+sz<=n else { ii+=1; continue }
    blocks.append(Blk(ct:ct, off:ii+9, sz:sz)); ii += 1
}

// Count all 0x2629 blocks
let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }

print("0x2629 count: \(all2629.count)")
print("0x262b count: \(all262b.count)")

// Combined pool: 0x2629 and 0x262b sorted by file offset
struct PoolEntry { let ct: UInt16; let off: Int; let sz: Int; var name: String = "" }
var combined: [PoolEntry] = []
for blk in all2629 { combined.append(PoolEntry(ct: blk.ct, off: blk.off, sz: blk.sz)) }
for blk in all262b { combined.append(PoolEntry(ct: blk.ct, off: blk.off, sz: blk.sz)) }
combined.sort { $0.off < $1.off }

// Get name for each pool entry via its 0x2628 child
for i in 0..<combined.count {
    let pEnd = combined[i].off + combined[i].sz
    guard let nb = all2628.first(where: { $0.off >= combined[i].off && $0.off+$0.sz <= pEnd }) else { continue }
    let nl = Int(u32le(nb.off))
    guard nl >= 1, nl <= 512, nb.off+4+nl <= n,
          let name = String(bytes: d[nb.off+4..<nb.off+4+nl], encoding: .utf8), !name.isEmpty else { continue }
    combined[i].name = name
}

print("\nCombined pool (\(combined.count) entries):")
for (i, e) in combined.enumerated() {
    let type = e.ct == 0x2629 ? "audio" : "cmpd"
    print("  combined[\(i)] \(type) '\(e.name)'")
}

// Now dump sentinel sections
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
guard all1054.count >= 2 else { print("Need 2x 0x1054"); exit(0) }
let s1054 = all1054[1]
let sStart = s1054.off, sEnd = s1054.off + s1054.sz
let inner1054Ranges = blocks.filter { $0.ct == 0x1054 && $0.off > sStart && $0.off+$0.sz <= sEnd }.map { ($0.off, $0.off+$0.sz) }
let sentinel1052s = blocks.filter { blk in
    guard blk.ct == 0x1052, blk.off >= sStart, blk.off+blk.sz <= sEnd else { return false }
    return !inner1054Ranges.contains { r in r.0 <= blk.off && blk.off+blk.sz <= r.1 }
}.sorted { $0.off < $1.off }

let SENTINEL: UInt64 = 1_000_000_000_000

print("\nSentinel 0x104f raw bytes (all, valid + invalid):")
for (ord, sec) in sentinel1052s.enumerated() {
    let secEnd = sec.off + sec.sz
    let refs = blocks.filter { $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd }.sorted { $0.off < $1.off }
    print("  sent[\(ord)] — \(refs.count) 0x104f blocks:")
    for r in refs {
        guard r.sz >= 19 else { print("    sz=\(r.sz) too small"); continue }
        let clipIdx16 = u16le(r.off + 2)
        let tl64 = u64le(r.off + 7)
        let byte18 = b(r.off + 18)
        let byte35 = r.sz >= 36 ? b(r.off + 35) : 0xff
        let isValid = tl64 >= SENTINEL
        let tag = isValid ? "" : "BELOW_SENTINEL"
        print("    clipIdx=\(clipIdx16) tl=\(tl64) byte18=0x\(String(format:"%02x",byte18)) byte35=0x\(String(format:"%02x",byte35)) \(tag)")
        if isValid {
            let relOff = Int64(bitPattern: tl64 - SENTINEL)
            let combinedName = clipIdx16 < combined.count ? combined[Int(clipIdx16)].name : "<INVALID>"
            print("      relOff=\(relOff) combined[\(clipIdx16)]='\(combinedName)'")
        }
    }
}
