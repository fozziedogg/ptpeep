import Foundation

// Investigate clip group placement at 255,893,638 (1:28:45:19).
// Goals:
//   1. Find the 0x104f at that position on "1 src" and "4 src" → show clipIdx
//   2. Decode what 0x2629 (pool parent) that clipIdx maps to
//   3. Decode 0x2423 group table: show all group definitions with their ordinals
//   4. Check if any 0x2629 blocks look like clip group entries (vs audio clip entries)

guard CommandLine.arguments.count > 1 else { print("Usage: dump_group_clip <file.ptx>"); exit(1) }
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    print("Cannot read file"); exit(1)
}
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
            let xorByte = table[(off >> 12) & 0xff]
            if xorByte != 0 { let end = min(off+4096, n); for j in off..<end { dPtr[j] = sPtr[j] ^ xorByte } }
            off += 4096
        }
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func u64le(_ i: Int) -> UInt64 { UInt64(u32le(i)) | UInt64(u32le(i+4))<<32 }
func hex(_ i: Int, _ c: Int) -> String { (0..<min(c,n-i)).map{String(format:"%02x",b(i+$0))}.joined(separator:" ") }
func str4(_ i: Int) -> String? {
    let nl = Int(u32le(i)); guard nl>0, nl<=512, i+4+nl<=n else { return nil }
    return String(bytes: d[i+4..<i+4+nl], encoding: .utf8)
}

struct Blk { let bt: UInt16; let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var i = 0x1f
while i + 9 <= n {
    guard b(i) == 0x5a else { i += 1; continue }
    let sz = Int(u32le(i+3))
    let ct = u16le(i+7)
    let bt = u16le(i+1)
    guard sz > 0, sz < 50_000_000, i+9+sz <= n else { i += 1; continue }
    blocks.append(Blk(bt: bt, ct: ct, off: i+9, sz: sz))
    i += 1
}
print("Total blocks: \(blocks.count)")

// ── Container 0 (first 0x1054) ────────────────────────────────────────────────
let containers = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
guard let container = containers.first else { print("No 0x1054"); exit(1) }
let cStart = container.off, cEnd = container.off + container.sz

// 0x1050 ranges (parent of 0x104f)
let sorted1050 = blocks.filter { $0.ct == 0x1050 && $0.off>=cStart && $0.off+$0.sz<=cEnd }.sorted { $0.off < $1.off }
let r1050 = sorted1050.map { ($0.off, $0.off+$0.sz) }

// 0x104f refs
let sorted104f = blocks.filter { $0.ct == 0x104f && $0.sz>=11 }.sorted { $0.off < $1.off }

// 0x1052 sections
let sections = blocks.filter { $0.ct==0x1052 && $0.off>=cStart && $0.off+$0.sz<=cEnd }.sorted { $0.off < $1.off }

// ── Find placements at 255,893,638 ────────────────────────────────────────────
let targetPos: Int64 = 255_893_638
let targetTracks = ["1 src", "4 src"]
print("\n=== 0x104f placements at \(targetPos) on src tracks ===")

var seenTrackNames: Set<String> = []
for sec in sections {
    guard let nm = str4(sec.off) else { continue }
    guard targetTracks.contains(nm), !seenTrackNames.contains(nm) else { continue }
    seenTrackNames.insert(nm)

    let sStart = sec.off, sEnd = sec.off + sec.sz
    var lo = 0, hi = sorted104f.count
    while lo < hi { let m=(lo+hi)/2; if sorted104f[m].off < sStart {lo=m+1} else {hi=m} }
    var j = lo
    while j < sorted104f.count {
        let ref = sorted104f[j]
        if ref.off >= sEnd { break }
        if ref.off+ref.sz <= sEnd {
            let clipIdx = Int(u16le(ref.off+2))
            let timeline = Int64(u32le(ref.off+7))
            if timeline == targetPos {
                // Find parent 0x1050
                var lo2=0, hi2=r1050.count
                while lo2<hi2 { let m=(lo2+hi2)/2; if r1050[m].0<=ref.off {lo2=m+1} else {hi2=m} }
                let idx2=lo2-1
                let hasParent = idx2>=0 && ref.off+ref.sz<=r1050[idx2].1
                let pOff = hasParent ? sorted1050[idx2].off : -1
                let fadeByte: UInt8 = (hasParent && pOff+24 < pOff+sorted1050[idx2].sz) ? b(pOff+24) : 0xff
                print("  Track '\(nm)': clipIdx=\(clipIdx) timeline=\(timeline) isFade=(byte24=0x\(String(format:"%02x",fadeByte)))")
                print("    0x104f data: \(hex(ref.off, min(ref.sz, 20)))")
                if hasParent { print("    0x1050 data: \(hex(pOff, min(sorted1050[idx2].sz, 48)))") }
            }
        }
        j += 1
    }
}

// ── Build sparse clip pool (0x2629 parents → 0x2628 child names) ──────────────
print("\n=== Clip pool lookup for clipIdx found above ===")
let parents2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let ranges2629 = parents2629.map { ($0.off, $0.off+$0.sz) }

func parentIdx2629(of blk: Blk) -> Int? {
    var lo=0, hi=ranges2629.count
    while lo<hi { let m=(lo+hi)/2; if ranges2629[m].0<=blk.off {lo=m+1} else {hi=m} }
    let idx=lo-1
    guard idx>=0, blk.off+blk.sz<=ranges2629[idx].1 else { return nil }
    return idx
}

var poolByIdx: [Int: (name: String, len: Int64)] = [:]
for blk in blocks where blk.ct == 0x2628 {
    guard let pIdx = parentIdx2629(of: blk) else { continue }
    guard poolByIdx[pIdx] == nil else { continue }
    guard let nm = str4(blk.off) else { continue }
    let nameLen = Int(u32le(blk.off))
    let afterName = blk.off + 4 + nameLen
    guard afterName + 1 < blk.off + blk.sz else { continue }
    guard b(afterName) == 0x00 else { continue }
    let lenOff = afterName + 1
    guard lenOff + 8 <= blk.off + blk.sz else { continue }
    let clipLen = Int64(u32le(lenOff))
    poolByIdx[pIdx] = (name: nm, len: clipLen)
}
print("Pool size: \(parents2629.count) slots, \(poolByIdx.count) valid entries")

// Look up the specific clipIdxs we care about
// We'll check a few around the target
for testIdx in [5700, 5710, 5720, 5730, 5740, 5750, 5760, 5770, 5780, 5790, 5800] {
    if let e = poolByIdx[testIdx] {
        print("  pool[\(testIdx)]: '\(e.name)' len=\(e.len)")
    }
}

// ── Decode 0x2423 group table ──────────────────────────────────────────────────
print("\n=== 0x2423 clip group definitions (first 20 + Group-06) ===")
var groupByOrdinal: [Int: String] = [:]
for blk in blocks.filter({ $0.ct == 0x2423 }) {
    guard blk.sz >= 8 else { continue }
    let ordinal = Int(u32le(blk.off))
    guard let nm = str4(blk.off + 4) else { continue }
    groupByOrdinal[ordinal] = nm
}
print("Total group definitions: \(groupByOrdinal.count)")
for (ord, nm) in groupByOrdinal.sorted(by: { $0.key < $1.key }).prefix(20) {
    print("  ordinal \(ord): '\(nm)'")
}
if let g06 = groupByOrdinal.first(where: { $0.value == "Group-06" }) {
    print("  Group-06 ordinal: \(g06.key)")
}

// ── Look at 0x2425 blocks — might be clip group pool entries ──────────────────
print("\n=== 0x2425 blocks (first 10) ===")
for blk in blocks.filter({ $0.ct == 0x2425 }).prefix(10) {
    print("  dataOff=\(blk.off) sz=\(blk.sz)")
    print("  data: \(hex(blk.off, min(64, blk.sz)))")
    // Try length-prefixed name
    if let nm = str4(blk.off) { print("  name?: '\(nm)'") }
}

// ── Check 0x2434 blocks ────────────────────────────────────────────────────────
print("\n=== 0x2434 blocks (first 5) ===")
for blk in blocks.filter({ $0.ct == 0x2434 }).prefix(5) {
    print("  dataOff=\(blk.off) sz=\(blk.sz)")
    print("  data: \(hex(blk.off, min(64, blk.sz)))")
    if let nm = str4(blk.off) { print("  name?: '\(nm)'") }
}

// ── Look at what block immediately follows the 0x2629 pool ────────────────────
// The group pool might start right after the audio clip pool
if let lastParent = parents2629.last {
    let afterPool = lastParent.off + lastParent.sz
    print("\n=== Bytes right after last 0x2629 block (pool ends at \(afterPool)) ===")
    print("  \(hex(afterPool - 9, 60))")  // include the last block header
}
