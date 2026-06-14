// Dump group placements on 1-4 split tracks: show clipIdx and the compound pool name we resolve.
// Compare against known correct names from honeybunch_PeepTest.txt / PeepTestC.txt
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

// Build compound pool: sorted 0x262b blocks, name extracted via first 0x2628 child
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

func compoundName(_ idx: Int) -> String {
    guard idx < all262b.count else { return "OUT-OF-RANGE[\(idx)/\(all262b.count)]" }
    let parent = all262b[idx]; let pEnd = parent.off + parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { return "<no 0x2628 child>" }
    let pos = child.off
    guard pos+4 < n else { return "<oob>" }
    let nl = Int(u32le(pos)); guard nl > 0, nl <= 512, pos+4+nl <= n else { return "<badnl \(nl)>" }
    return String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<utf8?>"
}

print("Total 0x262b (compound pool) entries: \(all262b.count)")

// Find 1-4 split track sections and dump group placements
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
let all1052 = blocks.filter { $0.ct == 0x1052 }.sorted { $0.off < $1.off }
let all104f = blocks.filter { $0.ct == 0x104f }.sorted { $0.off < $1.off }

guard let ft54 = all1054.first else { print("No 0x1054"); exit(0) }
let ft54End = ft54.off + ft54.sz

print("\nGroup placements on 1-4 split tracks:")
for trackName in ["1 split", "2 split", "3 split", "4 split"] {
    let secs = all1052.filter { sec in
        guard sec.off >= ft54.off && sec.off+sec.sz <= ft54End else { return false }
        let nl = sec.sz >= 4 ? Int(u32le(sec.off)) : 0
        guard nl > 0, nl <= 256, sec.off+4+nl <= n else { return false }
        return String(bytes: d[sec.off+4..<sec.off+4+nl], encoding: .utf8) == trackName
    }
    guard let sec = secs.first else { print("  \(trackName): section not found"); continue }
    let secEnd = sec.off + sec.sz
    let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }
    let groups = placements.filter { pl in
        guard pl.sz >= 36 else { return false }
        return b(pl.off+18) == 0x01 && b(pl.off+35) == 0x00
    }
    if groups.isEmpty { print("  \(trackName): no group placements"); continue }
    print("  \(trackName):")
    for pl in groups {
        let clipIdx = Int(u16le(pl.off+2))
        let tl = Int64(bitPattern: u64le(pl.off+7))
        let name = compoundName(clipIdx)
        print("    tl=\(tl) clipIdx=\(clipIdx) → '\(name)'")
    }
}

// Also dump the FIRST 10 and LAST 10 compound pool entries so we can see what's in there
print("\nFirst 10 compound pool entries:")
for idx in 0..<min(10, all262b.count) { print("  [\(idx)] '\(compoundName(idx))'") }
print("\nLast 10 compound pool entries:")
for idx in max(0, all262b.count-10)..<all262b.count { print("  [\(idx)] '\(compoundName(idx))'") }
