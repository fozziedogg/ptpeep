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
func readLE(_ i: Int, _ c: Int) -> UInt64 { var v: UInt64=0; for j in 0..<c { v |= UInt64(b(i+j))<<(j*8) }; return v }

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

let SENTINEL: Int64 = 1_000_000_000_000

// ── Audio clip pool (0x2629 → 0x2628) ────────────────────────────────────────
let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

print("=== Audio clip pool (0x2629) ===")
for (pi, parent) in all2629.enumerated() {
    let pEnd = parent.off + parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else {
        print("  clips[\(pi)] <no child>"); continue
    }
    let pos = child.off
    guard pos+4 < n else { continue }
    let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { print("  clips[\(pi)] <bad nl>"); continue }
    let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<?"
    // Parse the three-point section
    let tp = pos+4+Int(nl)
    guard tp+5 <= n else { print("  clips[\(pi)] '\(name)' <no tpt>"); continue }
    let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
    let nLength  = Int((b(tp+2) & 0xf0) >> 4)
    let nStart   = Int((b(tp+3) & 0xf0) >> 4)
    guard tp+5+nSrcOff+nLength <= n else { print("  clips[\(pi)] '\(name)' <tpt oob>"); continue }
    let srcOff = readLE(tp+5, nSrcOff)
    let length = readLE(tp+5+nSrcOff, nLength)
    let fileIdx = child.off+child.sz >= 2 ? Int(u16le(child.off+child.sz-2)) : -1
    print("  clips[\(pi)] '\(name)' len=\(Int64(bitPattern:length)) srcOff=\(Int64(bitPattern:srcOff)) fileIdx=\(fileIdx)")
}

// ── Sentinel expansion ────────────────────────────────────────────────────────
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
let all1052 = blocks.filter { $0.ct == 0x1052 }.sorted { $0.off < $1.off }
let all104f = blocks.filter { $0.ct == 0x104f }.sorted { $0.off < $1.off }

print("\n=== Sentinel expansion ===")
guard all1054.count >= 2 else { print("Only \(all1054.count) 0x1054 blocks — no sentinel container"); exit(0) }
let sent1054 = all1054[1]
let sStart = sent1054.off, sEnd = sStart + sent1054.sz
let inner1054Ranges = all1054.filter {
    $0.off > sStart && $0.off+$0.sz <= sEnd
}.map { ($0.off, $0.off+$0.sz) }
func inInner(_ bl: Blk) -> Bool {
    inner1054Ranges.contains { $0.0 <= bl.off && bl.off+bl.sz <= $0.1 }
}
let sentinel1052s = all1052.filter {
    $0.off >= sStart && $0.off+$0.sz <= sEnd && !inInner($0)
}.sorted { $0.off < $1.off }
print("Sentinel 0x1052 sections: \(sentinel1052s.count)")

func expand(ordinal: Int, baseOffset: Int64, depth: Int) -> [(audioClipIdx: Int, relOff: Int64)] {
    guard depth < 8, ordinal < sentinel1052s.count else { return [] }
    let sec = sentinel1052s[ordinal]
    let secEnd = sec.off + sec.sz
    let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }
    var result: [(Int, Int64)] = []
    for pl in placements {
        guard pl.sz >= 19 else { continue }
        let clipIdx = Int(u16le(pl.off+2))
        let tl = Int64(bitPattern: u64le(pl.off+7))
        guard tl >= SENTINEL else { continue }
        let relOff = baseOffset + (tl - SENTINEL)
        if b(pl.off+18) == 0x00 {
            result.append((clipIdx, relOff))
        } else {
            result += expand(ordinal: clipIdx, baseOffset: relOff, depth: depth+1)
        }
    }
    return result
}

for (ordinal, _) in sentinel1052s.enumerated() {
    let constituents = expand(ordinal: ordinal, baseOffset: 0, depth: 0)
    print("  sentinel[\(ordinal)] → \(constituents.count) leaf clips:")
    for c in constituents {
        let name = c.audioClipIdx < all2629.count ? {
            let parent = all2629[c.audioClipIdx]; let pEnd = parent.off+parent.sz
            guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { return "<no child>" }
            let pos = child.off; let nl = Int(u32le(pos))
            guard nl>0, nl<=512, pos+4+nl<=n else { return "<bad nl>" }
            return String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<utf8?>"
        }() : "OUT OF RANGE"
        print("    audioClipIdx=\(c.audioClipIdx) relOff=\(c.relOff) → '\(name)'")
    }
}

// ── Group placements in first 0x1054 ─────────────────────────────────────────
print("\n=== Group placements with constituent resolution ===")
guard let firstT54 = all1054.first else { print("No 0x1054"); exit(0) }
let ft54End = firstT54.off + firstT54.sz
let trackSections = all1052.filter { $0.off >= firstT54.off && $0.off+$0.sz <= ft54End }
for sec in trackSections {
    let secEnd = sec.off + sec.sz
    let nl = sec.sz >= 4 ? Int(u32le(sec.off)) : 0
    let trackName = (nl > 0 && nl <= 256 && sec.off+4+nl <= n)
        ? (String(bytes: d[sec.off+4..<sec.off+4+nl], encoding: .utf8) ?? "?") : "<>"
    let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }
    for pl in placements {
        guard pl.sz >= 19, b(pl.off+18) == 0x01 else { continue }
        let clipIdx = Int(u16le(pl.off+2))
        let tl = Int64(bitPattern: u64le(pl.off+7))
        print("  track='\(trackName)' groupPlacement clipIdx=\(clipIdx) tl=\(tl)")
        let constituents = clipIdx < sentinel1052s.count ? expand(ordinal: clipIdx, baseOffset: 0, depth: 0) : []
        print("  → \(constituents.count) constituents:")
        for c in constituents {
            let name = c.audioClipIdx < all2629.count ? {
                let parent = all2629[c.audioClipIdx]; let pEnd = parent.off+parent.sz
                guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { return "<no child>" }
                let pos = child.off; let nl2 = Int(u32le(pos))
                guard nl2>0, nl2<=512, pos+4+nl2<=n else { return "<bad nl>" }
                return String(bytes: d[pos+4..<pos+4+nl2], encoding: .utf8) ?? "<utf8?>"
            }() : "OUT OF RANGE"
            let absPos = tl + c.relOff
            print("    clips[\(c.audioClipIdx)] '\(name)' relOff=\(c.relOff) absPos=\(absPos)")
        }
    }
}
