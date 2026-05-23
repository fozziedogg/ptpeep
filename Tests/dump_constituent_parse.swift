import Foundation

// Dump compound pool (0x262b parents → 0x2628 children) with full constituent parsing.
// Uses proper PT10+ rolling XOR decode.
// Shows exactly what extractCompoundClips would see for each entry.

guard CommandLine.arguments.count > 1 else { print("Usage: dump_constituent_parse <file.ptx>"); exit(1) }
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    print("Cannot read file"); exit(1)
}
let n = raw.count

// PT10+ rolling XOR
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
            let xorByte = table[(off >> 12) & 0xff]
            if xorByte != 0 { let e = min(off+4096, n); for j in off..<e { dp[j] = sp[j] ^ xorByte } }
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

// Build 0x262b compound parent list (sorted by offset = pool ordinal)
let parents262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let parents262b_ranges = parents262b.map { ($0.off, $0.off + $0.sz) }
print("Compound pool (0x262b parents): \(parents262b.count)")

// Binary search: find which 0x262b parent contains a given 0x2628 block
func parentIdx262b(of blk: Blk) -> Int? {
    var lo = 0, hi = parents262b_ranges.count
    while lo < hi { let m=(lo+hi)/2; if parents262b_ranges[m].0<=blk.off {lo=m+1} else {hi=m} }
    let idx=lo-1
    guard idx>=0, blk.off+blk.sz <= parents262b_ranges[idx].1 else { return nil }
    return idx
}

// For each 0x262b parent, find its 0x2628 child and parse it
let sorted2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

for (pIdx, parent) in parents262b.enumerated() {
    print("\n=== Compound pool[\(pIdx)] 0x262b @\(parent.off) sz=\(parent.sz) ===")

    // Find the first 0x2628 child within this parent
    var lo = 0, hi = sorted2628.count
    while lo < hi { let m=(lo+hi)/2; if sorted2628[m].off < parent.off {lo=m+1} else {hi=m} }
    guard lo < sorted2628.count else { print("  No 0x2628 child found"); continue }
    let child = sorted2628[lo]
    guard child.off >= parent.off, child.off+child.sz <= parent.off+parent.sz else {
        print("  No 0x2628 child within parent range"); continue
    }
    print("  0x2628 child @\(child.off) sz=\(child.sz)")

    // Show raw bytes of the child
    print("  raw (first 80): \(hex(child.off, min(80, child.sz)))")

    let pos = child.off
    // nameLen
    guard pos+4 <= n else { print("  → too short for nameLen"); continue }
    let nl = Int(u32le(pos))
    guard nl >= 1, nl <= 512, pos+4+nl <= n else { print("  → invalid nameLen \(nl)"); continue }
    let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<non-utf8>"
    print("  name: '\(name)' (nl=\(nl))")

    // Three-point section
    let tp = pos + 4 + nl
    guard tp+5 <= n else { print("  → too short for three-point"); continue }
    let byte0 = b(tp)
    let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
    let nLength = Int((b(tp+2) & 0xf0) >> 4)
    let nStart  = Int((b(tp+3) & 0xf0) >> 4)
    print("  three-point: b0=\(String(format:"%02x",byte0)) nSrcOff=\(nSrcOff) nLength=\(nLength) nStart=\(nStart)")
    guard nSrcOff<=8, nLength<=8, nStart<=8, tp+5+nSrcOff+nLength+nStart <= n else {
        print("  → three-point out of range"); continue
    }
    var vp = tp + 5
    let srcOff = (0..<nSrcOff).reduce(UInt64(0)) { acc, i in acc | (UInt64(b(vp+i)) << (i*8)) }
    vp += nSrcOff
    let length = (0..<nLength).reduce(UInt64(0)) { acc, i in acc | (UInt64(b(vp+i)) << (i*8)) }
    vp += nLength
    let start  = (0..<nStart).reduce(UInt64(0)) { acc, i in acc | (UInt64(b(vp+i)) << (i*8)) }
    print("  srcOff=\(srcOff) length=\(length) start=\(start)")

    // Extra bytes (after three-point values, before last 2 fileIdx bytes)
    let extraStart = tp + 5 + nSrcOff + nLength + nStart
    let extraEnd   = child.off + child.sz - 2
    let extraLen   = extraEnd - extraStart
    print("  extraStart=\(extraStart) extraEnd=\(extraEnd) extraLen=\(extraLen)")

    if extraLen <= 0 { print("  → no extra bytes"); continue }

    // Show extra bytes in full (up to 200)
    print("  extra bytes: \(hex(extraStart, min(200, extraLen)))")

    // Parse constituent count at extra[24..27]
    let cntOffset = extraStart + 24
    if cntOffset + 4 <= extraEnd {
        let count = Int(u32le(cntOffset))
        print("  constituent count at extra[24]: \(count)")

        let firstBlock = extraStart + 28
        // Each constituent = 97 bytes (9-byte 0x2523 header + 88-byte content)
        print("  firstBlock=\(firstBlock) available=\(extraEnd - firstBlock) needed=\(count * 97)")

        if count > 0, count <= 64 {
            let needed = firstBlock + count * 97
            if needed <= extraEnd + 2 {
                print("  → size check PASSES")
                for i in 0..<count {
                    let tlOff  = extraStart + 60 + i * 97
                    let idxOff = extraStart + 76 + i * 97
                    guard idxOff + 4 <= extraEnd + 2 else { print("  → constituent \(i): offset overflow"); break }
                    let timeline     = u32le(tlOff)
                    let audioClipIdx = u32le(idxOff)
                    print("  constituent[\(i)]: timeline=\(timeline) audioClipIdx=\(audioClipIdx)")
                    // Show surrounding bytes for verification
                    print("    extra[\(60+i*97)..\(60+i*97+19)]: \(hex(extraStart+60+i*97, 20))")
                    print("    extra[\(76+i*97)..\(76+i*97+7)]: \(hex(extraStart+76+i*97, 8))")
                    // Also show the raw 97-byte chunk header
                    print("    chunk[\(i)] header: \(hex(extraStart+28+i*97, 9))")
                }
            } else {
                print("  → size check FAILS: needed=\(needed) > extraEnd+2=\(extraEnd+2)")
                // Show all of extra for manual inspection
                print("  full extra: \(hex(extraStart, extraLen))")
            }
        } else if count == 0 {
            print("  → count=0, no constituents")
        } else {
            print("  → count=\(count) exceeds sanity limit (64)")
        }
    } else {
        print("  → extra too short for constituent count (extraLen=\(extraLen) < 28)")
    }

    // File index (last 2 bytes)
    if child.sz >= 2 {
        let fileIdx = Int(u16le(child.off + child.sz - 2))
        print("  fileIdx (last 2 bytes): \(fileIdx)")
    }
}

// Summary: also verify the audio clip pool to cross-ref audioClipIdx values
let parents2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
print("\n=== Audio clip pool (0x2629): \(parents2629.count) parents ===")
// Show first 15 entries
let p2629_ranges = parents2629.map { ($0.off, $0.off + $0.sz) }
func audio_parentIdx(of blk: Blk) -> Int? {
    var lo = 0, hi = p2629_ranges.count
    while lo < hi { let m=(lo+hi)/2; if p2629_ranges[m].0<=blk.off {lo=m+1} else {hi=m} }
    let idx=lo-1
    guard idx>=0, blk.off+blk.sz <= p2629_ranges[idx].1 else { return nil }
    return idx
}
var audioPool: [Int: String] = [:]
for blk in sorted2628 {
    guard let pIdx = audio_parentIdx(of: blk) else { continue }
    guard audioPool[pIdx] == nil else { continue }
    if let nm = str4(blk.off) { audioPool[pIdx] = nm }
}
for i in 0..<min(20, parents2629.count) {
    print("  audio[\(i)]: '\(audioPool[i] ?? "<none>")' @\(parents2629[i].off)")
}
