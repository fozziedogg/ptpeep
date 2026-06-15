import Foundation

guard CommandLine.arguments.count > 1 else { print("Usage: dump_sentinel_match <file.ptx>"); exit(1) }
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let n = raw.count

// Rolling XOR decode (PT10+ format)
let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
for i: UInt16 in 0...255 {
    if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
}
var table = [UInt8](repeating: 0, count: 256)
for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
var d = raw
let src = Array(raw)
d.withUnsafeMutableBytes { dst in
    let dp = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
    var off = 4096
    while off < n {
        let xb = table[(off >> 12) & 0xff]
        if xb != 0 { let e = min(off+4096,n); for j in off..<e { dp[j] = src[j] ^ xb } }
        off += 4096
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func u64le(_ i: Int) -> UInt64 { UInt64(u32le(i)) | UInt64(u32le(i+4))<<32 }
func hex(_ i: Int, _ c: Int) -> String { (0..<min(c,n-i)).map{String(format:"%02x",b(i+$0))}.joined(separator:" ") }

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

func readVarint(_ data: Data, at offset: Int, count: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<count { v |= UInt64(b(offset+i)) << (i*8) }
    return v
}

// ── 1. Parse compound pool (0x262b → 0x2628 identity child) ──────────────────
struct CompoundEntry { let idx: Int; let name: String; let startSample: Int64; let lengthSamples: Int64 }
var compoundPool: [CompoundEntry] = []

let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

for (gi, parent) in all262b.enumerated() {
    let pEnd = parent.off + parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { continue }
    let pos = child.off
    guard pos+4 < n else { continue }
    let nl = Int(u32le(pos))
    guard nl > 0, nl <= 512, pos+4+nl <= n else { continue }
    let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<?"
    let tp = pos+4+nl
    guard tp+5 <= n else { continue }
    let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
    let nLength  = Int((b(tp+2) & 0xf0) >> 4)
    let nStart   = Int((b(tp+3) & 0xf0) >> 4)
    guard tp+5+nSrcOff+nLength+nStart <= n else { continue }
    var vp = tp+5+nSrcOff
    let lengthVal = readVarint(d, at: vp, count: nLength); vp += nLength
    let startVal  = readVarint(d, at: vp, count: nStart)
    compoundPool.append(CompoundEntry(idx: gi, name: name, startSample: Int64(bitPattern: startVal), lengthSamples: Int64(bitPattern: lengthVal)))
}
print("Compound pool entries: \(compoundPool.count)")
print("First 10 compound pool entries (idx, name, startSample, lengthSamples):")
for e in compoundPool.prefix(10) {
    print(String(format: "  [\(e.idx)] '\(e.name)' start=\(e.startSample) len=\(e.lengthSamples)"))
}

// ── 2. Find sentinel container (second 0x1054) ───────────────────────────────
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
print("\n0x1054 containers: \(all1054.count)")
guard all1054.count >= 2 else { print("Not enough 0x1054 containers"); exit(0) }
let sentinel1054 = all1054[1]
let sStart = sentinel1054.off, sEnd = sentinel1054.off + sentinel1054.sz

// ── 3. Find 0x1052 sections directly inside sentinel container ──────────────
// (Not nested inside other 0x1054 blocks inside the sentinel container)
let inner1054 = blocks.filter { $0.ct == 0x1054 && $0.off >= sStart && $0.off+$0.sz <= sEnd && $0.off != sStart }
let inner1054Ranges = inner1054.map { ($0.off, $0.off+$0.sz) }

func isInsideInner1054(_ bl: Blk) -> Bool {
    for (s, e) in inner1054Ranges { if bl.off >= s && bl.off+bl.sz <= e { return true } }
    return false
}

let sentinel1052s = blocks.filter {
    $0.ct == 0x1052 && $0.off >= sStart && $0.off+$0.sz <= sEnd && !isInsideInner1054($0)
}.sorted { $0.off < $1.off }
print("Direct 0x1052 sections in sentinel container: \(sentinel1052s.count)")
print("Inner nested 0x1054 inside sentinel: \(inner1054.count)")

// ── 4. For each sentinel 0x1052, find 0x104f children and extract positions ──
struct SentinelSection {
    let ordinal: Int
    let firstTL: Int64   // timeline of first 0x104f child (absolute = group.start + (tl - sentinel))
    let clipCount: Int
}
let SENTINEL: Int64 = 1_000_000_000_000

var sentinelSections: [SentinelSection] = []
for (si, sec) in sentinel1052s.enumerated() {
    let secEnd = sec.off + sec.sz
    let children104f = blocks.filter {
        $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd
    }.sorted { $0.off < $1.off }
    var firstTL: Int64 = 0
    if let first = children104f.first, first.off+15 <= n {
        firstTL = Int64(bitPattern: u64le(first.off+7))
    }
    sentinelSections.append(SentinelSection(ordinal: si, firstTL: firstTL, clipCount: children104f.count))
}
print("Sentinel sections with >=1 placement: \(sentinelSections.filter { $0.clipCount > 0 }.count)")
print("Sentinel sections with 0 placements: \(sentinelSections.filter { $0.clipCount == 0 }.count)")

// ── 5. Try to match sentinel sections to compound pool by start sample ────────
// sentinel firstTL - SENTINEL = relative offset from group start
// So group.startSample + (firstTL - SENTINEL) should equal the first constituent's timeline position
// But actually: sentinel firstTL IS the start of the first constituent relative to the sentinel base
// The sentinel's 0x104f tl = SENTINEL + constituentOffset
// group.startSample = 0x262b startSample
// constituent absolute position = group.startSample + (sentinelTL - SENTINEL)
// For the FIRST constituent, sentinelTL - SENTINEL = 0 (first clip starts at group start)
// So firstTL - SENTINEL ≈ 0 for the first constituent
// Therefore: group.startSample ≈ absolute position of first constituent

// Actually, we want to find: does compound[N]'s startSample match any sentinel section?
// The sentinel 0x1052 itself doesn't carry the group start — only the 0x104f inside it do
// The 0x104f tl = SENTINEL + (constituent.startSample - group.startSample)
// So if constituent starts at exactly group start: tl = SENTINEL + 0 = SENTINEL

// Let's look at what the sentinel firstTL values are
print("\nFirst 10 sentinel sections (ordinal, clipCount, firstTL, firstTL-SENTINEL):")
for s in sentinelSections.prefix(10) {
    let rel = s.firstTL - SENTINEL
    print("  [\(s.ordinal)] clips=\(s.clipCount) firstTL=\(s.firstTL) rel=\(rel)")
}

// ── 6. Cross-reference first 6 compound pool entries with sentinel sections ───
print("\nCross-reference (ordinal match — compound[N] vs sentinel[N]):")
for i in 0..<min(6, compoundPool.count, sentinelSections.count) {
    let c = compoundPool[i]
    let s = sentinelSections[i]
    let rel = s.firstTL > 0 ? s.firstTL - SENTINEL : 0
    print("  Compound[\(i)] '\(c.name)' start=\(c.startSample) | Sentinel[\(i)] clips=\(s.clipCount) firstRel=\(rel)")
}

// ── 7. Check if any compound pool entries have startSample == 0 ──────────────
let zeroStart = compoundPool.filter { $0.startSample == 0 }
let nonZeroStart = compoundPool.filter { $0.startSample != 0 }
print("\nCompound pool: \(zeroStart.count) with startSample=0, \(nonZeroStart.count) with nonzero")
print("First 5 with startSample=0:")
for e in zeroStart.prefix(5) {
    print("  [\(e.idx)] '\(e.name)' len=\(e.lengthSamples)")
}
