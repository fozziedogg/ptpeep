// For each sentinel, dump what expand() returns:
// audioClipIdx, relativeOffset, and whether that audioClipIdx is valid in the 0x2629 audio pool.
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

func readLE(_ off: Int, _ count: Int) -> UInt64 {
    var v: UInt64 = 0; for j in 0..<min(count,8) { if off+j < n { v |= UInt64(b(off+j)) << (j*8) } }; return v
}

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var ii = 0x1f; while ii+9 <= n {
    guard b(ii)==0x5a else { ii+=1; continue }
    let sz=Int(u32le(ii+3)); let ct=u16le(ii+7)
    guard sz>0, sz<50_000_000, ii+9+sz<=n else { ii+=1; continue }
    blocks.append(Blk(ct:ct, off:ii+9, sz:sz)); ii += 1
}

// Audio pool (0x2629→0x2628 children)
let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

var audioNames: [Int: String] = [:]
if let audioPool = all2629.first {
    let apEnd = audioPool.off + audioPool.sz
    let audioBlocks = all2628.filter { $0.off >= audioPool.off && $0.off+$0.sz <= apEnd }
    for (i, nb) in audioBlocks.enumerated() {
        let nl = Int(u32le(nb.off))
        guard nl >= 1, nl <= 512, nb.off+4+nl <= n,
              let name = String(bytes: d[nb.off+4..<nb.off+4+nl], encoding: .utf8), !name.isEmpty else { continue }
        audioNames[i] = name
    }
}
print("Audio pool (\(audioNames.count) entries):")
for i in 0..<audioNames.count { print("  audio[\(i)] = '\(audioNames[i] ?? "<nil>")'") }

// Also check 0x104e entries (track clip list entries - these have lengthSamples)
// The clips array in parser comes from 0x1050→0x104f or similar...
// Let me look at what block types appear near the audio pool for clip length

// Actually, let's look at the clip list which is used by the track placements.
// Clip lengths come from a clip list — likely 0x104e entries paired with 0x104f data.
// For now, let's focus on what expand() returns.

// Sentinel sections
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

func expand(ordinal: Int, baseOffset: Int64, depth: Int) -> [(clipIdx: Int, relOff: Int64, isCompound: Bool)] {
    guard depth < 8, ordinal < sentinel1052s.count else { return [] }
    let sec = sentinel1052s[ordinal]
    let secEnd = sec.off + sec.sz
    let refs = blocks.filter { $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd }.sorted { $0.off < $1.off }
    var result: [(clipIdx: Int, relOff: Int64, isCompound: Bool)] = []
    for r in refs {
        guard r.sz >= 19 else { continue }
        let clipIdx = Int(u16le(r.off + 2))
        let tl = u64le(r.off + 7)
        guard tl >= SENTINEL else { continue }
        let relOff = baseOffset + Int64(bitPattern: tl - SENTINEL)
        let isCompound = b(r.off + 18) == 0x01
        if isCompound {
            result += expand(ordinal: clipIdx, baseOffset: relOff, depth: depth+1)
        } else {
            result.append((clipIdx: clipIdx, relOff: relOff, isCompound: false))
        }
    }
    return result
}

print("\nExpand results per sentinel:")
for (ord, _) in sentinel1052s.enumerated() {
    let results = expand(ordinal: ord, baseOffset: 0, depth: 0)
    print("  sent[\(ord)]: \(results.count) leaf clips")
    for r in results {
        let name = audioNames[r.clipIdx] ?? "<INVALID idx=\(r.clipIdx)>"
        print("    audioIdx=\(r.clipIdx) '\(name)' relOff=\(r.relOff)")
    }
}
