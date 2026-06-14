import Foundation

guard CommandLine.arguments.count > 1 else { print("Usage: \(CommandLine.arguments[0]) <file.ptx> [ordinal]"); exit(1) }
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let targetOrdinal = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 415
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

// Audio clip pool (0x2629)
let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
print("Audio pool size: \(all2629.count)")

func clipName(_ idx: Int) -> String {
    guard idx < all2629.count else { return "OUT[\(idx)]" }
    let parent = all2629[idx]; let pEnd = parent.off+parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { return "<no child>" }
    let pos = child.off; guard pos+4 < n else { return "<oob>" }
    let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { return "<badnl \(u32le(pos))>" }
    return String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<utf8?>"
}

// Sentinel sections
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
let all1052 = blocks.filter { $0.ct == 0x1052 }.sorted { $0.off < $1.off }
let all104f = blocks.filter { $0.ct == 0x104f }.sorted { $0.off < $1.off }

print("0x1054 blocks: \(all1054.count)")
guard all1054.count >= 2 else { print("Need >=2 0x1054"); exit(0) }
let sent1054 = all1054[1]
let sStart = sent1054.off, sEnd = sStart + sent1054.sz
let inner1054Ranges = all1054.filter { $0.off > sStart && $0.off+$0.sz <= sEnd }
    .map { ($0.off, $0.off+$0.sz) }
func inInner(_ bl: Blk) -> Bool {
    inner1054Ranges.contains { $0.0 <= bl.off && bl.off+bl.sz <= $0.1 }
}
let sentinel1052s = all1052.filter {
    $0.off >= sStart && $0.off+$0.sz <= sEnd && !inInner($0)
}.sorted { $0.off < $1.off }
print("Sentinel 0x1052 sections: \(sentinel1052s.count)")

// Expand sentinel for given ordinal
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

// Compound pool name
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
func compoundName(_ idx: Int) -> String {
    guard idx < all262b.count else { return "OUT[\(idx)]" }
    let parent = all262b[idx]; let pEnd = parent.off+parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { return "<no child>" }
    let pos = child.off; guard pos+4 < n else { return "<oob>" }
    let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { return "<badnl>" }
    return String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<utf8?>"
}

// Show the target group and its constituents
print("\n=== Group compound[\(targetOrdinal)] = '\(compoundName(targetOrdinal))' ===")
let groupTL: Int64 = 188885472  // hardcoded for the '1 split' group in honeybunch

let constituents = expand(ordinal: targetOrdinal, baseOffset: 0, depth: 0)
print("Constituents from sentinel[\(targetOrdinal)]: \(constituents.count)")
for c in constituents.prefix(10) {
    let absPos = groupTL + c.relOff
    print("  clipIdx=\(c.audioClipIdx) relOff=\(c.relOff) absPos=\(absPos) name='\(clipName(c.audioClipIdx))'")
}

// Now show the regular placements on '1 split' near that range
print("\n=== Regular placements on '1 split' near 188885472 ===")
// Find '1 split' 0x1052 section in first 0x1054
let ft54 = all1054[0]; let ft54End = ft54.off + ft54.sz
let trackSecs = all1052.filter { $0.off >= ft54.off && $0.off+$0.sz <= ft54End }
for sec in trackSecs {
    let nl = sec.sz >= 4 ? Int(u32le(sec.off)) : 0
    guard nl > 0, nl <= 256, sec.off+4+nl <= n,
          let name = String(bytes: d[sec.off+4..<sec.off+4+nl], encoding: .utf8),
          name == "1 split" else { continue }
    let secEnd = sec.off + sec.sz
    let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }
    let rangeStart: Int64 = 188000000
    let rangeEnd:   Int64 = 190000000
    for pl in placements {
        guard pl.sz >= 19 else { continue }
        let clipIdx = Int(u16le(pl.off+2))
        let tl = Int64(bitPattern: u64le(pl.off+7))
        guard tl >= rangeStart && tl <= rangeEnd else { continue }
        let b18 = b(pl.off+18)
        let b0  = b(pl.off)
        let b35 = pl.sz >= 36 ? b(pl.off+35) : 0xff
        let nm = b18 == 0x01 ? "GROUP→\(compoundName(clipIdx))" : "clip→\(clipName(clipIdx))"
        print("  tl=\(tl) b18=0x\(String(format:"%02x",b18)) b0=0x\(String(format:"%02x",b0)) b35=0x\(String(format:"%02x",b35)) \(nm)")
    }
    break
}
