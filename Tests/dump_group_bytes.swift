// Dump raw bytes of 0x104f group placements at tl=188885472 on 1-4 split tracks.
// Want to see exactly what clipIdx bytes are in the file.
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
func u16be(_ i: Int) -> UInt16 { UInt16(b(i))<<8 | UInt16(b(i+1)) }
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

let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
let all1052 = blocks.filter { $0.ct == 0x1052 }.sorted { $0.off < $1.off }
let all104f = blocks.filter { $0.ct == 0x104f }.sorted { $0.off < $1.off }
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

func compoundName(_ idx: Int) -> String {
    guard idx < all262b.count else { return "OUT[\(idx)/\(all262b.count)]" }
    let p = all262b[idx]; let pEnd = p.off+p.sz
    guard let c = all2628.first(where: { $0.off >= p.off && $0.off+$0.sz <= pEnd }) else { return "<no child>" }
    let nl = Int(u32le(c.off)); guard nl>0, nl<=512, c.off+4+nl<=n else { return "<bad>" }
    return String(bytes: d[c.off+4..<c.off+4+nl], encoding: .utf8) ?? "<?>"
}

guard let ft54 = all1054.first else { print("No 0x1054"); exit(0) }
let ft54End = ft54.off + ft54.sz

let targetTL: Int64 = 188885472

print("All 0x104f group placements at tl=\(targetTL) on 1-4 split tracks:")
print("(showing first 40 raw bytes, byte[0]=mute, [1]=?, [2..3]=clipIdx LE, [7..14]=tl int64, [18]=type, [35]=hidden)")
print()

for trackName in ["1 split", "2 split", "3 split", "4 split"] {
    let secs = all1052.filter { sec in
        guard sec.off >= ft54.off && sec.off+sec.sz <= ft54End else { return false }
        let nl = sec.sz >= 4 ? Int(u32le(sec.off)) : 0
        guard nl>0, nl<=256, sec.off+4+nl<=n else { return false }
        return String(bytes: d[sec.off+4..<sec.off+4+nl], encoding: .utf8) == trackName
    }
    guard let sec = secs.first else { continue }
    let secEnd = sec.off + sec.sz
    let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }

    for pl in placements {
        guard pl.sz >= 19 else { continue }
        let tl = Int64(bitPattern: u64le(pl.off+7))
        guard tl == targetTL else { continue }
        let b18 = b(pl.off+18)
        let b35 = pl.sz >= 36 ? b(pl.off+35) : 0xff
        let clipIdxLE = Int(u16le(pl.off+2))
        let clipIdxBE = Int(u16be(pl.off+2))
        let bytes = (0..<min(40, pl.sz)).map { String(format:"%02x", b(pl.off+$0)) }.joined(separator:" ")
        print("  \(trackName): b18=0x\(String(b18,radix:16)) b35=0x\(String(b35,radix:16))")
        print("    clipIdx LE=\(clipIdxLE) BE=\(clipIdxBE)")
        print("    name(LE)='\(compoundName(clipIdxLE))'  name(BE)='\(compoundName(clipIdxBE))'")
        print("    bytes: \(bytes)")
        print()
    }
}
