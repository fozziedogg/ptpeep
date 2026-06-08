import Foundation

// Investigate how group clip clipIdx values map to the compound pool.
// Hypothesis: clipIdx for group clips (byte18==0x01 in 0x104f) is an index into
// the COMBINED clip pool — audio (0x2629) + compound (0x262b) parents sorted by
// file offset — not just into the compound pool alone.
//
// Usage: swift dump_group_pool_idx.swift <file.ptx>

guard CommandLine.arguments.count > 1 else { print("Usage: dump_group_pool_idx <file.ptx>"); exit(1) }
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    print("Cannot read file"); exit(1)
}
let n = raw.count

// ── PT10+ rolling XOR decode ──────────────────────────────────────────────────
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
            let xorByte = table[(off >> 12) & 0xff]
            if xorByte != 0 { let e = min(off+4096, n); for j in off..<e { dPtr[j] = sPtr[j] ^ xorByte } }
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
    let nl = Int(u32le(i)); guard nl>0, nl<=512, i+4+nl<=n else { return nil }
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
print("Total blocks: \(blocks.count)")

// ── 1. Build the COMBINED clip pool (0x2629 + 0x262b sorted by file offset) ──
// This is our hypothesis: clipIdx = ordinal in this combined list.
struct PoolParent { let ct: UInt16; let off: Int; let sz: Int; var name: String? }
var combinedPool: [PoolParent] = []
for blk in blocks where blk.ct == 0x2629 || blk.ct == 0x262b {
    combinedPool.append(PoolParent(ct: blk.ct, off: blk.off, sz: blk.sz, name: nil))
}
combinedPool.sort { $0.off < $1.off }

// Resolve names: each pool parent contains a 0x2628 child.
// Find the 0x2628 child of each parent and read its name.
let sorted2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
let parentRanges = combinedPool.map { ($0.off, $0.off + $0.sz) }
func nameInParent(at pIdx: Int) -> String? {
    let (pStart, pEnd) = parentRanges[pIdx]
    // Binary search for first 0x2628 whose offset >= pStart
    var lo = 0, hi = sorted2628.count
    while lo < hi { let m=(lo+hi)/2; if sorted2628[m].off < pStart {lo=m+1} else {hi=m} }
    let j = lo
    guard j < sorted2628.count else { return nil }
    let child = sorted2628[j]
    guard child.off >= pStart, child.off+child.sz <= pEnd else { return nil }
    return str4(child.off)
}
for i in 0..<combinedPool.count {
    combinedPool[i].name = nameInParent(at: i)
}

let audioCount    = combinedPool.filter { $0.ct == 0x2629 }.count
let compoundCount = combinedPool.filter { $0.ct == 0x262b }.count
print("Combined pool: \(combinedPool.count) entries (\(audioCount) audio 0x2629, \(compoundCount) compound 0x262b)")

// Show the first few compound entries and their COMBINED ordinal position
print("\n=== Compound (0x262b) entries in combined pool ===")
for (i, p) in combinedPool.enumerated() where p.ct == 0x262b {
    print("  combined[\(i)] 0x262b name='\(p.name ?? "<none>")' @\(p.off)")
}

// ── 2. Scan 0x104f blocks with byte18==0x01 (group clips) ────────────────────
// For each, show clipIdx and what the combined pool resolves to.
let sorted104f = blocks.filter { $0.ct == 0x104f && $0.sz >= 37 }.sorted { $0.off < $1.off }
let groupRefs  = sorted104f.filter { b($0.off+18) == 0x01 }
print("\n=== Group placements (0x104f byte[18]==0x01): \(groupRefs.count) total ===")
if groupRefs.isEmpty {
    print("  None found — byte18 may not be the group indicator in this file.")
    // Show a sample of 0x104f blocks to check what byte18 looks like
    print("\n=== Sample 0x104f blocks (byte18 values) ===")
    for ref in sorted104f.prefix(20) {
        let byte0  = b(ref.off)
        let byte18 = b(ref.off+18)
        let byte35 = b(ref.off+35)
        let clipIdx = Int(u16le(ref.off+2))
        let timeline = Int64(u32le(ref.off+7))
        print("  @\(ref.off) clipIdx=\(clipIdx) tl=\(timeline) b0=\(String(format:"%02x",byte0)) b18=\(String(format:"%02x",byte18)) b35=\(String(format:"%02x",byte35))")
    }
} else {
    for ref in groupRefs.prefix(30) {
        let clipIdx  = Int(u16le(ref.off+2))
        let timeline = Int64(u32le(ref.off+7))
        let byte0    = b(ref.off)
        let byte35   = b(ref.off+35)

        var resolvedCombined = "OUT_OF_RANGE"
        var resolvedName = "<none>"
        if clipIdx < combinedPool.count {
            let p = combinedPool[clipIdx]
            resolvedCombined = p.ct == 0x262b ? "compound" : "audio(0x2629)"
            resolvedName = p.name ?? "<no_name>"
        }

        // Also try: if compound pool only (separate from audio), what ordinal?
        let compoundOnlyOrdinal = clipIdx - audioCount
        var resolvedCompoundOnly = "n/a"
        let compoundEntries = combinedPool.filter { $0.ct == 0x262b }
        if compoundOnlyOrdinal >= 0, compoundOnlyOrdinal < compoundEntries.count {
            resolvedCompoundOnly = compoundEntries[compoundOnlyOrdinal].name ?? "<no_name>"
        }

        print("  clipIdx=\(clipIdx) tl=\(timeline) muted=\(byte0==1) hidden=\(byte35==1)")
        print("    combined[\(clipIdx)] → \(resolvedCombined) '\(resolvedName)'")
        print("    compound-only[\(compoundOnlyOrdinal)] → '\(resolvedCompoundOnly)'")
        print("    raw: \(hex(ref.off, 20))")
    }
}

// ── 3. Also check for non-byte18 group indicators ─────────────────────────────
// Show all distinct byte values at positions 0,1,2,4,18,19,35 across 0x104f blocks
print("\n=== Byte distribution in 0x104f blocks (positions 0,4,18,19,20,21,34,35,36) ===")
var dist: [Int: [UInt8: Int]] = [:]
for pos in [0,4,18,19,20,21,34,35,36] { dist[pos] = [:] }
for ref in sorted104f {
    for pos in [0,4,18,19,20,21,34,35,36] {
        guard ref.off+pos < ref.off+ref.sz else { continue }
        dist[pos]![b(ref.off+pos), default: 0] += 1
    }
}
for pos in [0,4,18,19,20,21,34,35,36].sorted() {
    let vals = dist[pos]!.sorted { $0.key < $1.key }.map { String(format:"0x%02x×%d",$0.key,$0.value) }.joined(separator:", ")
    print("  byte[\(pos)]: \(vals)")
}

// ── 4. Show how many 0x104f blocks reference clipIdx > audioCount ─────────────
let overAudioCount = sorted104f.filter { Int(u16le($0.off+2)) >= audioCount }
print("\n=== 0x104f with clipIdx >= audioCount (\(audioCount)): \(overAudioCount.count) ===")
for ref in overAudioCount.prefix(10) {
    let clipIdx = Int(u16le(ref.off+2))
    let byte18  = b(ref.off+18)
    let compOrdinal = clipIdx - audioCount
    let compEntries = combinedPool.filter { $0.ct == 0x262b }
    let resolvedName = compOrdinal >= 0 && compOrdinal < compEntries.count ? (compEntries[compOrdinal].name ?? "<no_name>") : "OOB"
    print("  clipIdx=\(clipIdx) byte18=\(String(format:"%02x",byte18)) compOrdinal=\(compOrdinal) name='\(resolvedName)'")
}
