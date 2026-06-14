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
func readLE(_ i: Int, _ c: Int) -> UInt64 { var v: UInt64=0; for j in 0..<c { v |= UInt64(b(i+j))<<(j*8) }; return v }

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
do {
    var i = 0x1f; while i+9 <= n {
        guard b(i)==0x5a else { i+=1; continue }
        let sz=Int(u32le(i+3)); let ct=u16le(i+7)
        guard sz>0, sz<50_000_000, i+9+sz<=n else { i+=1; continue }
        blocks.append(Blk(ct:ct, off:i+9, sz:sz)); i += 1
    }
}

let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

// Check compound pool entries 39, 68, 415, 472, 473 (from the 1-4split groups)
let targets = [39, 68, 415, 472, 473, 474]
print("Compound pool lengths for relevant groups:")
for idx in targets {
    guard idx < all262b.count else { print("  [\(idx)] out of range"); continue }
    let parent = all262b[idx]; let pEnd = parent.off+parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else {
        print("  [\(idx)] <no child>"); continue
    }
    let pos = child.off
    guard pos+4 < n else { continue }
    let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { continue }
    let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<?"
    let tp = pos+4+Int(nl); guard tp+5 <= n else { continue }
    let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
    let nLength  = Int((b(tp+2) & 0xf0) >> 4)
    let nStart   = Int((b(tp+3) & 0xf0) >> 4)
    guard tp+5+nSrcOff+nLength+nStart <= n else { continue }
    let startVal = readLE(tp+5+nSrcOff+nLength, nStart)
    let lengthVal = readLE(tp+5+nSrcOff, nLength)
    print("  [\(idx)] '\(name)' start=\(Int64(bitPattern:startVal)) length=\(Int64(bitPattern:lengthVal))")
}

// Specifically for the 1-split group: what is the group at tl=188885472?
// Find the compound pool index used by the group placement at 188885472 on '1 split'
print("\nGroup placements on 1-4 split tracks at ~188885472:")
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
let all1052 = blocks.filter { $0.ct == 0x1052 }.sorted { $0.off < $1.off }
let all104f = blocks.filter { $0.ct == 0x104f }.sorted { $0.off < $1.off }
guard let ft54 = all1054.first else { exit(0) }
let ft54End = ft54.off + ft54.sz

for trackName in ["1 split", "2 split", "3 split", "4 split"] {
    let secs = all1052.filter { sec -> Bool in
        guard sec.off >= ft54.off && sec.off+sec.sz <= ft54End else { return false }
        let nl = sec.sz >= 4 ? Int(u32le(sec.off)) : 0
        guard nl > 0 && nl <= 256 && sec.off+4+nl <= n else { return false }
        return String(bytes: d[sec.off+4..<sec.off+4+nl], encoding: .utf8) == trackName
    }
    guard let sec = secs.first else { continue }
    let secEnd = sec.off + sec.sz
    let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }
    for pl in placements {
        guard pl.sz >= 19 else { continue }
        let tl = Int64(bitPattern: u64le(pl.off+7))
        guard tl > 188000000 && tl < 190000000 else { continue }
        let clipIdx = Int(u16le(pl.off+2))
        let b18 = b(pl.off+18); let b35 = pl.sz >= 36 ? b(pl.off+35) : 0xff
        guard b35 == 0x00 else { continue }

        if b18 == 0x01 {
            // Group - look up compound pool length
            guard clipIdx < all262b.count else { print("  \(trackName) tl=\(tl) GROUP clipIdx=\(clipIdx) OUT"); continue }
            let parent = all262b[clipIdx]; let pEnd = parent.off+parent.sz
            guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { continue }
            let pos = child.off
            guard pos+4 < n else { continue }
            let nl2 = Int(u32le(pos)); guard nl2>0, nl2<=512, pos+4+nl2<=n else { continue }
            let name = String(bytes: d[pos+4..<pos+4+nl2], encoding: .utf8) ?? "<?"
            let tp = pos+4+Int(nl2); guard tp+5 <= n else { continue }
            let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
            let nLength  = Int((b(tp+2) & 0xf0) >> 4)
            let nStart   = Int((b(tp+3) & 0xf0) >> 4)
            guard tp+5+nSrcOff+nLength+nStart <= n else { continue }
            let lengthVal = readLE(tp+5+nSrcOff, nLength)
            let startVal = readLE(tp+5+nSrcOff+nLength, nStart)
            let groupEnd = tl + Int64(bitPattern: lengthVal)
            print("  \(trackName) tl=\(tl) GROUP '\(name)' start=\(Int64(bitPattern:startVal)) length=\(Int64(bitPattern:lengthVal)) groupEnd=\(groupEnd)")
        } else {
            print("  \(trackName) tl=\(tl) clip")
        }
    }
}
