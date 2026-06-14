// Try to determine the correct sentinel→compound mapping.
// Approach: check if 0x262b blocks contain a 0x2523 with a field pointing to the sentinel ordinal.
// Also check the 0x1050 wrappers inside each sentinel section.
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
    var off = 4096; while off < n {
        let xb = table[(off >> 12) & 0xff]
        if xb != 0 { let e = min(off+4096,n); for j in off..<e { dp[j]=src[j]^xb } }; off += 4096
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func u64le(_ i: Int) -> UInt64 { UInt64(u32le(i)) | UInt64(u32le(i+4))<<32 }
func hex(_ i: Int, _ c: Int) -> String { (0..<min(c,max(0,n-i))).map { String(format:"%02x",b(i+$0)) }.joined(separator:" ") }

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var ii = 0x1f; while ii+9 <= n {
    guard b(ii)==0x5a else { ii+=1; continue }
    let sz=Int(u32le(ii+3)); let ct=u16le(ii+7)
    guard sz>0, sz<50_000_000, ii+9+sz<=n else { ii+=1; continue }
    blocks.append(Blk(ct:ct, off:ii+9, sz:sz)); ii += 1
}

let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
let all2523 = blocks.filter { $0.ct == 0x2523 }.sorted { $0.off < $1.off }
let all2526 = blocks.filter { $0.ct == 0x2526 }.sorted { $0.off < $1.off }
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }

guard all1054.count >= 2 else { print("Need 2x 0x1054"); exit(0) }
let s1054 = all1054[1]
let sStart = s1054.off, sEnd = s1054.off + s1054.sz

let inner1054Ranges = blocks.filter { $0.ct == 0x1054 && $0.off > sStart && $0.off+$0.sz <= sEnd }.map { ($0.off, $0.off+$0.sz) }
let sentinel1052s = blocks.filter { blk in
    guard blk.ct == 0x1052, blk.off >= sStart, blk.off+blk.sz <= sEnd else { return false }
    return !inner1054Ranges.contains { r in r.0 <= blk.off && blk.off+blk.sz <= r.1 }
}.sorted { $0.off < $1.off }

let SENTINEL: UInt64 = 1_000_000_000_000

// Combined pool
let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
var combined: [(ct: UInt16, off: Int, sz: Int)] = []
for blk in all2629 { combined.append((ct: blk.ct, off: blk.off, sz: blk.sz)) }
for blk in all262b { combined.append((ct: blk.ct, off: blk.off, sz: blk.sz)) }
combined.sort { $0.off < $1.off }

// Compound name lookup
func compoundName(_ idx: Int) -> String {
    guard idx < all262b.count else { return "<oob>" }
    let cp = all262b[idx]; let cpEnd = cp.off + cp.sz
    guard let nb = all2628.first(where: { $0.off >= cp.off && $0.off+$0.sz <= cpEnd }) else { return "<noname>" }
    let nl = Int(u32le(nb.off))
    guard nl >= 1, nl <= 512, nb.off+4+nl <= n,
          let name = String(bytes: d[nb.off+4..<nb.off+4+nl], encoding: .utf8) else { return "<bad>" }
    return name
}

// For each sentinel, find the compound it belongs to by looking at its PARENT structure.
// The sentinel 0x1052 blocks are inside the second 0x1054. But is there an intermediate
// container (like a 0x262b or 0x262c) that wraps each sentinel and identifies the compound?

// Check what's between consecutive sentinels — are there parent blocks?
print("=== Sentinel positions and inter-sentinel blocks ===")
for (ord, sec) in sentinel1052s.enumerated() {
    let secHeader = sec.off - 9
    print("sent[\(ord)] header=0x\(String(secHeader, radix:16)) content_off=0x\(String(sec.off, radix:16)) sz=\(sec.sz)")
    // Show 0x104f first entry for context
    let secEnd = sec.off + sec.sz
    let refs = blocks.filter { $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd }.sorted { $0.off < $1.off }
    for r in refs.prefix(2) {
        let ci = u16le(r.off + 2); let tl = u64le(r.off + 7); let b18 = b(r.off + 18)
        let cn = ci < combined.count ? (combined[Int(ci)].ct == 0x262b ? "cmpd" : "audio") : "??"
        let combinedName: String
        if ci < combined.count {
            let pEnd = combined[Int(ci)].off + combined[Int(ci)].sz
            let nameBlock = all2628.first { $0.off >= combined[Int(ci)].off && $0.off+$0.sz <= pEnd }
            if let nb = nameBlock {
                let nl = Int(u32le(nb.off))
                if nl >= 1, nl <= 512, nb.off+4+nl <= n, let nm = String(bytes: d[nb.off+4..<nb.off+4+nl], encoding: .utf8) {
                    combinedName = nm
                } else { combinedName = "<bad>" }
            } else { combinedName = "<noname>" }
        } else { combinedName = "<oob>" }
        if tl >= SENTINEL {
            let rel = Int64(bitPattern: tl - SENTINEL)
            print("  clipIdx=\(ci)(\(cn)) '\(combinedName)' relOff=\(rel) byte18=0x\(String(format:"%02x",b18))")
        }
    }
}

// Now: for each compound, look at its 0x2523 blocks and extract tail[14..15]
// Previously noted as "sequential global ID". Maybe it maps to sentinel ordinal.
print("\n=== Compound 0x2523 tail[14..15] (potential sentinel ordinal) ===")
for (idx, cp) in all262b.enumerated() {
    let cpEnd = cp.off + cp.sz
    guard let nb = all2628.first(where: { $0.off >= cp.off && $0.off+$0.sz <= cpEnd }) else { continue }
    let my2523 = all2523.filter { $0.off >= nb.off && $0.off+$0.sz <= nb.off+nb.sz }.sorted { $0.off < $1.off }
    var s23IDs: [UInt16] = []
    for s23 in my2523 {
        // 0x2523 has a 0x2526 child; tail after 0x2526 includes tail[14..15]
        if let s26 = all2526.first(where: { $0.off > s23.off && $0.off+$0.sz <= s23.off+s23.sz }) {
            let after = s26.off + s26.sz
            if after + 16 <= n {
                let v14 = u16le(after + 14)
                s23IDs.append(v14)
            }
        }
    }
    let name = compoundName(idx)
    print("  cmpd[\(idx)] '\(name)': 0x2523 tail[14..15] = \(s23IDs)")
}

// Also: the 0x1050 blocks immediately wrapping 0x104f inside sentinel sections
// — check if they contain a compound reference
print("\n=== 0x1050 wrappers in sentinel sections ===")
let all1050 = blocks.filter { $0.ct == 0x1050 }.sorted { $0.off < $1.off }
for (ord, sec) in sentinel1052s.enumerated() {
    let secEnd = sec.off + sec.sz
    let wrappers = all1050.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }.sorted { $0.off < $1.off }
    for w in wrappers.prefix(1) {
        print("  sent[\(ord)] 0x1050 sz=\(w.sz): \(hex(w.off, min(32, w.sz)))")
    }
}
