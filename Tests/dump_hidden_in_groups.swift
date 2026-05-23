import Foundation

// For each group clip (0x104f byte[18]==0x01), find all placements on the same
// 0x1052 section whose timeline falls within the group's range.
// Test hypothesis: constituent clips of a compound group are stored as HIDDEN
// placements (byte[35]==0x01) at the constituent positions on the same track.

guard CommandLine.arguments.count > 1 else { print("Usage: <file.ptx>"); exit(1) }
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
        guard sz>0,sz<50_000_000,i+9+sz<=n else { i+=1; continue }
        blocks.append(Blk(ct:ct, off:i+9, sz:sz))
        i += 1
    }
}

// Compound pool: ordinal → (name, start, length)
let parents262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let pRanges262b = parents262b.map { ($0.off, $0.off + $0.sz) }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
var compoundPool: [Int: (name: String, start: Int64, length: Int64)] = [:]
for (pIdx, parent) in parents262b.enumerated() {
    var lo = 0, hi = all2628.count
    while lo < hi { let m=(lo+hi)/2; if all2628[m].off < parent.off {lo=m+1} else {hi=m} }
    guard lo < all2628.count else { continue }
    let child = all2628[lo]; guard child.off+child.sz <= parent.off+parent.sz else { continue }
    guard let nm = str4(child.off) else { continue }
    let nl = Int(u32le(child.off))
    let tp = child.off + 4 + nl; guard tp+5 <= n else { continue }
    let nStart = Int((b(tp+3) & 0xf0) >> 4)
    let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
    let nLength = Int((b(tp+2) & 0xf0) >> 4)
    var vp = tp + 5 + nSrcOff
    let length = (0..<nLength).reduce(UInt64(0)) { acc, i in acc | (UInt64(b(vp+i)) << (i*8)) }; vp += nLength
    let start  = (0..<nStart ).reduce(UInt64(0)) { acc, i in acc | (UInt64(b(vp+i)) << (i*8)) }
    compoundPool[pIdx] = (name: nm, start: Int64(bitPattern: start), length: Int64(bitPattern: length))
}

// Audio clip pool for name lookup (from 0x2629 parents → 0x2628 children)
let parents2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let pRanges2629 = parents2629.map { ($0.off, $0.off + $0.sz) }
var audioPool: [Int: String] = [:]
for child in all2628 {
    var lo = 0, hi = pRanges2629.count
    while lo < hi { let m=(lo+hi)/2; if pRanges2629[m].0<=child.off {lo=m+1} else {hi=m} }
    let idx = lo-1; guard idx >= 0, child.off+child.sz <= pRanges2629[idx].1 else { continue }
    guard audioPool[idx] == nil, let nm = str4(child.off) else { continue }
    audioPool[idx] = nm
}

// Find main 0x1054 container
guard let container = blocks.filter({ $0.ct == 0x1054 }).sorted(by: { $0.sz > $1.sz }).first else {
    print("No 0x1054"); exit(1)
}
let cStart = container.off, cEnd = container.off + container.sz
print("Main 0x1054 @\(cStart) sz=\(container.sz)")

// 0x1050 wrappers within container (validate 0x104f placements)
let sorted1050 = blocks.filter { $0.ct == 0x1050 && $0.off >= cStart && $0.off+$0.sz <= cEnd }.sorted { $0.off < $1.off }
let r1050 = sorted1050.map { ($0.off, $0.off+$0.sz) }
func has1050(for ref: Blk) -> Bool {
    var lo = 0, hi = r1050.count
    while lo < hi { let m=(lo+hi)/2; if r1050[m].0<=ref.off {lo=m+1} else {hi=m} }
    let idx=lo-1; guard idx >= 0 else { return false }
    return ref.off+ref.sz <= r1050[idx].1
}

// 0x1052 sections
let sections = blocks.filter { $0.ct == 0x1052 && $0.off >= cStart && $0.off+$0.sz <= cEnd }.sorted { $0.off < $1.off }

// Sorted 0x104f refs within container
let sortedRefs = blocks.filter { $0.ct == 0x104f && $0.sz >= 37 && $0.off >= cStart && $0.off+$0.sz <= cEnd }.sorted { $0.off < $1.off }

// For each 0x1052 section, collect all placements (hidden+visible)
for sec in sections {
    let sName = str4(sec.off) ?? "<no_name>"
    let sStart = sec.off, sEnd = sec.off + sec.sz
    var lo = 0, hi = sortedRefs.count
    while lo < hi { let m=(lo+hi)/2; if sortedRefs[m].off < sStart {lo=m+1} else {hi=m} }
    var j = lo
    var allRefs: [Blk] = []
    while j < sortedRefs.count && sortedRefs[j].off < sEnd {
        if sortedRefs[j].off+sortedRefs[j].sz <= sEnd { allRefs.append(sortedRefs[j]) }
        j += 1
    }

    // Find group placements in this section
    let groupRefs = allRefs.filter { b($0.off+18) == 0x01 && has1050(for: $0) }
    guard !groupRefs.isEmpty else { continue }

    print("\n=== Track '\(sName)' — \(groupRefs.count) group clip(s) ===")
    for gRef in groupRefs {
        let clipIdx  = Int(u16le(gRef.off+2))
        let timeline = Int64(u32le(gRef.off+7))
        guard let entry = compoundPool[clipIdx] else { print("  group clipIdx=\(clipIdx) not in compound pool"); continue }
        let groupEnd = entry.start + entry.length
        print("\n  Group '\(entry.name)' clipIdx=\(clipIdx) tl=\(timeline) range=[\(entry.start)..\(groupEnd)] len=\(entry.length)")

        // Find ALL 0x104f placements on this track within the group's range
        let inRange = allRefs.filter { ref in
            guard has1050(for: ref) else { return false }
            let tl = Int64(u32le(ref.off+7))
            return tl >= entry.start && tl < groupEnd
        }
        print("  Placements within group range (\(inRange.count) total):")
        for ref in inRange {
            let refClipIdx = Int(u16le(ref.off+2))
            let refTl = Int64(u32le(ref.off+7))
            let byte0  = b(ref.off)
            let byte18 = b(ref.off+18)
            let byte35 = b(ref.off+35)
            let isGroup = byte18 == 0x01
            let isHidden = byte35 == 0x01
            let clipName = isGroup ? (compoundPool[refClipIdx]?.name ?? "?") : (audioPool[refClipIdx] ?? "?")
            print("    clipIdx=\(refClipIdx) tl=\(refTl) muted=\(byte0==1) group=\(isGroup) hidden=\(isHidden) name='\(clipName)'")
        }
    }
}
