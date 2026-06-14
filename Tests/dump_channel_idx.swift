import Foundation

// Investigate where channel index [N] is stored in PTX binary.
// Strategy: find the 0x2629 pool indices for specific named clips, then find their 0x104f
// timeline placements and dump the full 0x104f bytes for comparison.

guard CommandLine.arguments.count > 1 else { print("Usage: dump_channel_idx <file.ptx> [clipname...]"); exit(1) }
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    print("Cannot read file"); exit(1)
}
let searchNames = CommandLine.arguments.count > 2 ? Array(CommandLine.arguments[2...]) : []
let n = raw.count

// XOR decode
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

// ── Build 0x2629 pool index map (clip name → pool index) ──────────────────────
let parents2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let ranges2629 = parents2629.map { ($0.off, $0.off + $0.sz) }

func parentIndex(of blk: Blk) -> Int? {
    var lo=0, hi=ranges2629.count
    while lo < hi { let m=(lo+hi)/2; if ranges2629[m].0<=blk.off {lo=m+1} else {hi=m} }
    let idx=lo-1
    guard idx>=0, blk.off+blk.sz<=ranges2629[idx].1 else { return nil }
    return idx
}

struct ClipInfo { let poolIdx: Int; let name: String }
var clipPool: [ClipInfo] = []
var clipByName: [String: Int] = [:]  // name → pool index

for blk in blocks where blk.ct == 0x2628 {
    guard let pIdx = parentIndex(of: blk) else { continue }
    guard clipByName.values.contains(pIdx) == false else { continue }
    guard let nm = str4(blk.off) else { continue }
    if clipByName[nm] == nil {
        clipByName[nm] = pIdx
    }
}

// Find pool indices for target clips
print("\n=== Target clip pool indices ===")
var targetPoolIndices: Set<Int> = []
for (name, idx) in clipByName.sorted(by: { $0.key < $1.key }) {
    if searchNames.isEmpty || searchNames.contains(where: { name.contains($0) }) {
        print("  pool[\(idx)]: '\(name)'")
        targetPoolIndices.insert(idx)
    }
}

// ── Find 0x104f blocks referencing those pool indices ─────────────────────────
print("\n=== 0x104f placements for target clips ===")
let refs104f = blocks.filter { $0.ct == 0x104f && $0.sz >= 12 }.sorted { $0.off < $1.off }

// Find the 0x1052 sections (track playlists) to show track names
let sections1052 = blocks.filter { $0.ct == 0x1052 }.sorted { $0.off < $1.off }
let section1052Ranges = sections1052.map { ($0.off, $0.off + $0.sz) }

func trackNameFor(refOff: Int) -> String? {
    var lo=0, hi=section1052Ranges.count
    while lo < hi { let m=(lo+hi)/2; if section1052Ranges[m].0<=refOff {lo=m+1} else {hi=m} }
    let idx=lo-1
    guard idx>=0, refOff<=section1052Ranges[idx].1 else { return nil }
    return str4(sections1052[idx].off)
}

for ref in refs104f {
    let clipIdx = Int(u16le(ref.off + 2))
    guard targetPoolIndices.contains(clipIdx) else { continue }
    let timelinePos = Int64(u32le(ref.off + 7))
    let trackName = trackNameFor(refOff: ref.off) ?? "?"
    let discByte = ref.sz > 35 ? b(ref.off + 35) : 0xff
    let hidden = discByte == 0x01
    print("  track='\(trackName)' clipIdx=\(clipIdx) timeline=\(timelinePos) disc=0x\(String(format:"%02x",discByte)) \(hidden ? "[HIDDEN]" : "[VISIBLE]")")
    print("  full bytes[\(ref.sz)]: \(hex(ref.off, ref.sz))")
    print()
}

// ── Also dump 0x2628 blocks for target clips ──────────────────────────────────
print("\n=== 0x2628 block bytes for target clips ===")
for blk in blocks where blk.ct == 0x2628 {
    guard let nm = str4(blk.off) else { continue }
    guard searchNames.isEmpty || searchNames.contains(where: { nm.contains($0) }) else { continue }
    let nameLen = Int(u32le(blk.off))
    let afterName = blk.off + 4 + nameLen
    let blkEnd = blk.off + blk.sz
    let poolIdx = parentIndex(of: blk) ?? -1
    print("pool[\(poolIdx)] '\(nm)': sz=\(blk.sz)")
    print("  after-name hex: \(hex(afterName, blkEnd - afterName))")
}
