// Dump track placements (isGroup) with their clipIdx values,
// and the compound pool names indexed by those values.
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

// Build compound pool names (0x262b→0x2628)
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

var compoundNames: [Int: String] = [:]
for (idx, cp) in all262b.enumerated() {
    let cpEnd = cp.off + cp.sz
    guard let nb = all2628.first(where: { $0.off >= cp.off && $0.off+$0.sz <= cpEnd }) else { continue }
    let nl = Int(u32le(nb.off))
    guard nl >= 1, nl <= 512, nb.off+4+nl <= n,
          let name = String(bytes: d[nb.off+4..<nb.off+4+nl], encoding: .utf8), !name.isEmpty else { continue }
    compoundNames[idx] = name
}

print("=== Compound pool (\(all262b.count) entries) ===")
for i in 0..<all262b.count {
    print("  cmpd[\(i)] = '\(compoundNames[i] ?? "<no name>")'")
}

// Build sentinel sections
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
var sentinelCount = 0
if all1054.count >= 2 {
    let s1054 = all1054[1]
    let sStart = s1054.off, sEnd = s1054.off + s1054.sz
    let inner1054Ranges = blocks.filter { $0.ct == 0x1054 && $0.off > sStart && $0.off+$0.sz <= sEnd }.map { ($0.off, $0.off+$0.sz) }
    let sentinel1052s = blocks.filter { blk in
        guard blk.ct == 0x1052, blk.off >= sStart, blk.off+blk.sz <= sEnd else { return false }
        return !inner1054Ranges.contains { r in r.0 <= blk.off && blk.off+blk.sz <= r.1 }
    }.sorted { $0.off < $1.off }
    sentinelCount = sentinel1052s.count
    print("\n=== \(sentinelCount) sentinel sections ===")
    for (ord, s) in sentinel1052s.enumerated() {
        let sEnd2 = s.off + s.sz
        let refs = blocks.filter { $0.ct == 0x104f && $0.off >= s.off && $0.off+$0.sz <= sEnd2 }.sorted { $0.off < $1.off }
        let SENTINEL: UInt64 = 1_000_000_000_000
        var validRefs = 0
        for r in refs {
            guard r.sz >= 19 else { continue }
            let tl = u64le(r.off + 7)
            if tl >= SENTINEL { validRefs += 1 }
        }
        print("  sent[\(ord)]: \(validRefs) valid 0x104f refs")
    }
}

// Find track placements (isGroup, byte18==0x01)
// Track playlists are in first 0x1054
guard let firstContainer = blocks.filter({ $0.ct == 0x1054 }).sorted(by: { $0.off < $1.off }).first else {
    print("No 0x1054"); exit(0)
}
let cStart = firstContainer.off, cEnd = firstContainer.off + firstContainer.sz

// Find 1052s in the first container
let trackSections = blocks.filter { $0.ct == 0x1052 && $0.off >= cStart && $0.off+$0.sz <= cEnd }.sorted { $0.off < $1.off }
print("\n=== Track sections: \(trackSections.count) ===")

// For each 1052, find its name via sibling 0x1051
let all1051 = blocks.filter { $0.ct == 0x1051 }.sorted { $0.off < $1.off }

let SENTINEL: UInt64 = 1_000_000_000_000

for (ti, sec) in trackSections.enumerated() {
    let secEnd = sec.off + sec.sz
    // Find 0x104f children
    let refs = blocks.filter { $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd }.sorted { $0.off < $1.off }
    let groups = refs.filter { r in r.sz >= 19 && d[r.off+18] == 0x01 }
    guard !groups.isEmpty else { continue }

    // Get track name: find 0x1051 just before this 0x1052
    let trackName: String
    if let nb = all1051.last(where: { $0.off < sec.off }) {
        let nl = Int(u32le(nb.off))
        if nl >= 1, nl <= 256, nb.off+4+nl <= n,
           let name = String(bytes: d[nb.off+4..<nb.off+4+nl], encoding: .utf8) {
            trackName = name
        } else { trackName = "?" }
    } else { trackName = "?" }

    print("\nTrack '\(trackName)' [section \(ti)] — \(groups.count) group placements:")
    for r in groups {
        let clipIdx = Int(u16le(r.off + 2))
        let tl32 = u32le(r.off + 7)
        let tl64 = u64le(r.off + 7)
        let isPhantom = tl64 >= SENTINEL
        let name = compoundNames[clipIdx] ?? "<no compound name>"
        print("  clipIdx=\(clipIdx) → '\(name)'  tl32=\(tl32) tl64=\(tl64) \(isPhantom ? "PHANTOM(sentinel)" : "")")
    }
}
