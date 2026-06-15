// Check the ordinal mapping between compound pool entries and sentinel sections.
// For compound pool entry [415] = '1 split.grp-06', what does sentinel[415] actually contain?
// And which sentinel ordinal actually has the correct clips for that group?
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

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var i = 0x1f; while i+9 <= n {
    guard b(i)==0x5a else { i+=1; continue }
    let sz=Int(u32le(i+3)); let ct=u16le(i+7)
    guard sz>0, sz<50_000_000, i+9+sz<=n else { i+=1; continue }
    blocks.append(Blk(ct:ct, off:i+9, sz:sz)); i += 1
}

// Build compound pool
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }

func compoundName(_ idx: Int) -> String {
    guard idx < all262b.count else { return "OUT[\(idx)]" }
    let p = all262b[idx]
    guard let c = all2628.first(where: { $0.off >= p.off && $0.off+$0.sz <= p.off+p.sz }) else { return "<no child>" }
    let nl = Int(u32le(c.off)); guard nl>0,nl<=512,c.off+4+nl<=n else { return "<bad>" }
    return String(bytes: d[c.off+4..<c.off+4+nl], encoding: .utf8) ?? "<?>"
}

// Audio clip pool name
func audioClipName(_ idx: Int) -> String {
    guard idx < all2629.count else { return "OUT[\(idx)]" }
    let p = all2629[idx]
    guard let c = all2628.first(where: { $0.off >= p.off && $0.off+$0.sz <= p.off+p.sz }) else { return "<no child>" }
    let nl = Int(u32le(c.off)); guard nl>0,nl<=512,c.off+4+nl<=n else { return "<bad>" }
    return String(bytes: d[c.off+4..<c.off+4+nl], encoding: .utf8) ?? "<?>"
}

// Find sentinel container (second 0x1054)
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
guard all1054.count >= 2 else { print("Need 2x 0x1054"); exit(0) }
let sentContainer = all1054[1]
let scStart = sentContainer.off, scEnd = sentContainer.off + sentContainer.sz

// All 0x1052 sections inside sentinel container
let sentSections = blocks.filter { $0.ct == 0x1052 && $0.off >= scStart && $0.off+$0.sz <= scEnd }
    .sorted { $0.off < $1.off }

print("Compound pool entries: \(all262b.count)")
print("Sentinel sections: \(sentSections.count)")
print("Audio clip pool entries: \(all2629.count)")

// The SENTINEL: 1e12 + relOff
let SENTINEL: UInt64 = 1_000_000_000_000

// Expand sentinel section at ordinal, return constituents
func expandSentinel(_ ordinal: Int) -> [(relOff: Int64, audioIdx: Int, name: String)] {
    guard ordinal < sentSections.count else { return [] }
    let sec = sentSections[ordinal]
    let secEnd = sec.off + sec.sz
    let all104f = blocks.filter { $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd }
    var results: [(Int64, Int, String)] = []
    for ref in all104f {
        guard ref.sz >= 19 else { continue }
        let tl = u64le(ref.off+7)
        guard tl >= SENTINEL else { continue }
        let relOff = Int64(bitPattern: tl - SENTINEL)
        let audioIdx = Int(u16le(ref.off+2))
        let byte18 = b(ref.off+18)
        guard byte18 == 0x00 else { continue } // leaf audio clip only
        results.append((relOff, audioIdx, audioClipName(audioIdx)))
    }
    return results
}

// Show what sentinel[415] gives us (current mapping for '1 split.grp-06')
print("\n--- Current mapping: compound[415]='1 split.grp-06' → sentinel[415] ---")
let s415 = expandSentinel(415)
print("sentinel[415] constituents: \(s415.count)")
for c in s415 { print("  relOff=\(c.relOff) audioIdx=\(c.audioIdx) '\(c.name)'") }

// Also show compound[415] start/length
let cp415 = all262b[415]
if let child = all2628.first(where: { $0.off >= cp415.off && $0.off+$0.sz <= cp415.off+cp415.sz }) {
    let pos = child.off
    let nl = Int(u32le(pos))
    let tp = pos+4+nl
    if tp+5 <= n {
        let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
        let nLength  = Int((b(tp+2) & 0xf0) >> 4)
        let nStart   = Int((b(tp+3) & 0xf0) >> 4)
        var vp = tp+5+nSrcOff
        func readLE2(_ i: Int, _ c: Int) -> UInt64 { var v: UInt64=0; for j in 0..<c { v |= UInt64(b(i+j))<<(j*8) }; return v }
        let len = readLE2(vp, nLength); vp += nLength
        let start = readLE2(vp, nStart)
        print("  compound[415] start=\(start) length=\(len) end=\(start+len)")
    }
}

// Now search: which sentinel ordinal actually has clips named '04-05T01'?
// (These are the correct clips for that group position per PeepTestC)
print("\n--- Searching for sentinel section that contains '04-05T01' clips ---")
for ord in 0..<min(sentSections.count, 600) {
    let cs = expandSentinel(ord)
    if cs.contains(where: { $0.name.contains("04-05T01") }) {
        print("sentinel[\(ord)] (compound='\(compoundName(ord))') has '04-05T01' clips:")
        for c in cs { print("  relOff=\(c.relOff) '\(c.name)'") }
    }
}

// Show a range around 415 to see what neighbours look like
print("\n--- Sentinel sections 410-420 ---")
for ord in 410...420 {
    let cs = expandSentinel(ord)
    let names = cs.prefix(2).map { "'\($0.name)'" }.joined(separator: ", ")
    print("  sentinel[\(ord)] compound='\(compoundName(ord))' → \(cs.count) constituents: \(names)")
}
