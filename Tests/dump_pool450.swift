import Foundation

// Show everything about 0x2629 pool entry #450 and its children,
// and look for any block type that maps clipIdx → group ordinal.

guard CommandLine.arguments.count > 1 else { print("need ptx"); exit(1) }
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
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
        let dPtr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let sPtr = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var off = 4096
        while off < n {
            let xb = table[(off >> 12) & 0xff]
            if xb != 0 { let e=min(off+4096,n); for j in off..<e { dPtr[j]=sPtr[j]^xb } }
            off += 4096
        }
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func hex(_ i: Int, _ c: Int) -> String { (0..<min(c,n-i)).map{String(format:"%02x",b(i+$0))}.joined(separator:" ") }

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var i = 0x1f
while i+9 <= n {
    guard b(i)==0x5a else { i+=1; continue }
    let sz=Int(u32le(i+3)); let ct=u16le(i+7)
    guard sz>0, sz<50_000_000, i+9+sz<=n else { i+=1; continue }
    blocks.append(Blk(ct:ct, off:i+9, sz:sz))
    i += 1
}

// ── 1. Find 0x2629 parent #450 ─────────────────────────────────────────────────
let parents = blocks.filter { $0.ct==0x2629 }.sorted { $0.off < $1.off }
guard parents.count > 450 else { print("Not enough 0x2629 parents"); exit(1) }
let p450 = parents[450]
print("=== 0x2629 parent #450 ===")
print("  dataOff=\(p450.off) sz=\(p450.sz)")
print("  data: \(hex(p450.off, min(p450.sz, 64)))")

// Show ALL blocks contained within this parent
print("  Children (all block types inside parent):")
for blk in blocks {
    if blk.off >= p450.off && blk.off+blk.sz <= p450.off+p450.sz {
        print("    ct=0x\(String(format:"%04x",blk.ct)) off=\(blk.off) sz=\(blk.sz)")
        print("    data: \(hex(blk.off, min(blk.sz, 48)))")
        // Try length-prefixed string
        if blk.sz >= 4 {
            let nl = Int(u32le(blk.off))
            if nl > 0, nl <= 512, blk.off+4+nl <= n {
                if let s = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
                    print("    → name: '\(s)'")
                }
            }
        }
    }
}

// ── 2. Also check parents 449-453 to see pattern ──────────────────────────────
print("\n=== 0x2629 parents 449-453 (context) ===")
for idx in 449...453 {
    guard idx < parents.count else { break }
    let p = parents[idx]
    print("  parent[\(idx)] off=\(p.off) sz=\(p.sz): \(hex(p.off, min(16, p.sz)))")
    // Find first 0x2628 child
    for blk in blocks where blk.ct==0x2628 && blk.off>=p.off && blk.off+blk.sz<=p.off+p.sz {
        let nl = Int(u32le(blk.off))
        if nl > 0, nl <= 512, blk.off+4+nl <= n,
           let s = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
            print("    0x2628 name: '\(s)'")
        } else {
            print("    0x2628 raw: \(hex(blk.off, min(blk.sz, 24)))")
        }
        break
    }
}

// ── 3. Look for 0x2628 blocks near pool[450] that might be group refs ─────────
print("\n=== All 0x2628 children of parent[450] ===")
var childCount = 0
for blk in blocks where blk.ct==0x2628 && blk.off>=p450.off && blk.off+blk.sz<=p450.off+p450.sz {
    childCount += 1
    print("  child #\(childCount): off=\(blk.off) sz=\(blk.sz)")
    print("    raw: \(hex(blk.off, min(blk.sz, 48)))")
    let nl = Int(u32le(blk.off))
    if nl > 0, nl <= 512, blk.off+4+nl <= n,
       let s = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
        print("    → name: '\(s)'")
    }
}
if childCount == 0 { print("  No 0x2628 children found") }

// ── 4. Collect ALL clipIdx values from group placements (byte9=0x01) ──────────
print("\n=== Distribution of clipIdx for group placements (byte9=0x01) ===")
let containers1054 = blocks.filter { $0.ct==0x1054 }.sorted { $0.off < $1.off }
guard let cont = containers1054.first else { print("No 0x1054"); exit(1) }
let cStart = cont.off, cEnd = cont.off + cont.sz

let sorted1050 = blocks.filter { $0.ct==0x1050 && $0.off>=cStart && $0.off+$0.sz<=cEnd }.sorted { $0.off < $1.off }
let sorted104f = blocks.filter { $0.ct==0x104f && $0.sz>=11 }.sorted { $0.off < $1.off }
let r1050 = sorted1050.map { ($0.off, $0.off+$0.sz) }

var groupClipIdxs: [Int] = []
for ref in sorted104f {
    var lo=0, hi=r1050.count
    while lo<hi { let m=(lo+hi)/2; if r1050[m].0<=ref.off {lo=m+1} else {hi=m} }
    let idx=lo-1
    guard idx>=0, ref.off+ref.sz<=r1050[idx].1 else { continue }
    let pOff = sorted1050[idx].off
    let pSz  = sorted1050[idx].sz
    guard pOff+10 < pOff+pSz else { continue }
    let byte9 = b(pOff+9)
    if byte9 == 0x01 {
        let clipIdx = Int(u16le(ref.off+2))
        groupClipIdxs.append(clipIdx)
    }
}
let minIdx = groupClipIdxs.min() ?? 0
let maxIdx = groupClipIdxs.max() ?? 0
print("Total group placements: \(groupClipIdxs.count)")
print("clipIdx range: \(minIdx) – \(maxIdx)")
print("Unique clipIdxs: \(Set(groupClipIdxs).count)")
let sorted = Set(groupClipIdxs).sorted()
print("First 20 unique: \(Array(sorted.prefix(20)))")

// ── 5. For group clipIdx values, check if pool entry has a 0x2628 with name ────
print("\n=== 0x2628 content for first 5 unique group clipIdxs ===")
for idx in sorted.prefix(5) {
    guard idx < parents.count else { continue }
    let parent = parents[idx]
    print("  pool[\(idx)]: parent off=\(parent.off)")
    var found = false
    for blk in blocks where blk.ct==0x2628 && blk.off>=parent.off && blk.off+blk.sz<=parent.off+parent.sz {
        let nl = Int(u32le(blk.off))
        if nl > 0, nl <= 512, blk.off+4+nl <= n,
           let s = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
            print("    0x2628: '\(s)'")
        } else {
            print("    0x2628 raw: \(hex(blk.off, min(blk.sz, 24)))")
        }
        found = true
        break
    }
    if !found { print("    no 0x2628 child") }
}
