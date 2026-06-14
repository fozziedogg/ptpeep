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
    var off = 4096
    while off < n {
        let xb = table[(off >> 12) & 0xff]
        if xb != 0 { let e = min(off+4096,n); for j in off..<e { dp[j]=src[j]^xb } }
        off += 4096
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func u64le(_ i: Int) -> UInt64 { UInt64(u32le(i)) | UInt64(u32le(i+4))<<32 }

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

func readLE(_ offset: Int, count: Int) -> UInt64 {
    var v: UInt64 = 0; for i in 0..<count { v |= UInt64(b(offset+i)) << (i*8) }; return v
}

// Compound pool
struct CEntry { let idx: Int; let name: String; let startSample: Int64 }
var compoundPool: [CEntry] = []
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
for (gi, parent) in all262b.enumerated() {
    let pEnd = parent.off + parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { continue }
    let pos = child.off
    guard pos+4 < n else { continue }
    let nl = Int(u32le(pos)); guard nl > 0, nl <= 512, pos+4+nl <= n else { continue }
    let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<?"
    let tp = pos+4+nl; guard tp+5 <= n else { continue }
    let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
    let nLength  = Int((b(tp+2) & 0xf0) >> 4)
    let nStart   = Int((b(tp+3) & 0xf0) >> 4)
    guard tp+5+nSrcOff+nLength+nStart <= n else { continue }
    var vp = tp+5+nSrcOff+nLength
    let startVal = readLE(vp, count: nStart)
    compoundPool.append(CEntry(idx: gi, name: name, startSample: Int64(bitPattern: startVal)))
}

// Sentinel container
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
guard all1054.count >= 2 else { print("Need 2 0x1054"); exit(0) }
let sentinel1054 = all1054[1]
let sStart = sentinel1054.off, sEnd = sentinel1054.off + sentinel1054.sz

let sentinel1052s = blocks.filter {
    $0.ct == 0x1052 && $0.off >= sStart && $0.off+$0.sz <= sEnd
}.sorted { $0.off < $1.off }

// For each sentinel section, get clip count and startSample of first placement
struct SEntry { let ordinal: Int; let clipCount: Int; let firstAbsStart: Int64 }
var sentinelSections: [SEntry] = []
let SENTINEL: Int64 = 1_000_000_000_000
for (si, sec) in sentinel1052s.enumerated() {
    let secEnd = sec.off + sec.sz
    let children = blocks.filter {
        $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd
    }.sorted { $0.off < $1.off }
    var firstAbs: Int64 = 0
    if let first = children.first, first.off+15 <= n {
        firstAbs = Int64(bitPattern: u64le(first.off+7))
    }
    sentinelSections.append(SEntry(ordinal: si, clipCount: children.count, firstAbsStart: firstAbs))
}

print("Compound pool: \(compoundPool.count), Sentinel sections: \(sentinelSections.count)")

// Show entries around the boundary (490-495 for compound, and last 6 sentinel)
print("\nCompound pool entries [488..495]:")
for i in 488..<min(496, compoundPool.count) {
    let c = compoundPool[i]
    print("  [\(i)] '\(c.name)' start=\(c.startSample)")
}

print("\nLast 10 sentinel sections [483..492]:")
for i in max(0, sentinelSections.count-10)..<sentinelSections.count {
    let s = sentinelSections[i]
    let rel = s.clipCount > 0 ? s.firstAbsStart - SENTINEL : -1
    print("  [\(i)] clips=\(s.clipCount) firstRel=\(rel)")
}

// The extra 77: show compound[493..502]
print("\nCompound pool extras (beyond sentinel count) [493..502]:")
for i in 493..<min(503, compoundPool.count) {
    let c = compoundPool[i]
    print("  [\(i)] '\(c.name)' start=\(c.startSample)")
}

// Now check: do the 0x104f group placements (byte18==0x01) reference compound idx < 493?
let all104f = blocks.filter { $0.ct == 0x104f }
let groupPlacements = all104f.filter { bl in
    bl.off+19 <= n && b(bl.off+18) == 0x01
}
var groupClipIdxs = Set<Int>()
for bl in groupPlacements {
    guard bl.off+4 <= n else { continue }
    let clipIdx = Int(u16le(bl.off+2))
    groupClipIdxs.insert(clipIdx)
}
print("\nGroup placements (byte18==0x01): \(groupPlacements.count), unique clipIdxs: \(groupClipIdxs.count)")
let maxIdx = groupClipIdxs.max() ?? 0
let minIdx = groupClipIdxs.min() ?? 0
print("clipIdx range: \(minIdx)..\(maxIdx)")
// How many have clipIdx >= 493?
let highIdx = groupClipIdxs.filter { $0 >= 493 }
print("clipIdxs >= 493: \(highIdx.sorted())")
