// Dump specific compound pool entries by index, and also search for "Group-" named entries
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

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var i = 0x1f; while i+9 <= n {
    guard b(i)==0x5a else { i+=1; continue }
    let sz=Int(u32le(i+3)); let ct=u16le(i+7)
    guard sz>0, sz<50_000_000, i+9+sz<=n else { i+=1; continue }
    blocks.append(Blk(ct:ct, off:i+9, sz:sz)); i += 1
}

let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

func entryName(_ idx: Int) -> String {
    guard idx < all262b.count else { return "OUT[\(idx)/\(all262b.count)]" }
    let p = all262b[idx]; let pEnd = p.off+p.sz
    guard let c = all2628.first(where: { $0.off >= p.off && $0.off+$0.sz <= pEnd }) else { return "<no 0x2628>" }
    let nl = Int(u32le(c.off)); guard nl>0, nl<=512, c.off+4+nl<=n else { return "<bad nl=\(nl)>" }
    return String(bytes: d[c.off+4..<c.off+4+nl], encoding: .utf8) ?? "<?>"
}

print("Total 0x262b entries: \(all262b.count)")
print()

// Entries the app is claiming to show
print("Entry [70]:  '\(entryName(70))'")
print("Entry [183]: '\(entryName(183))'")
print()

// Correct entries per our diagnostic
print("Entry [89]:  '\(entryName(89))'   (3-split clipIdx LE)")
print("Entry [90]:  '\(entryName(90))'   (4-split clipIdx LE)")
print("Entry [415]: '\(entryName(415))'  (1-split clipIdx LE)")
print("Entry [416]: '\(entryName(416))'  (2-split clipIdx LE)")
print()

// Search ALL entries for "Group" in the name
print("All entries with 'Group' in the name:")
for idx in 0..<all262b.count {
    let nm = entryName(idx)
    if nm.contains("Group") || nm.contains("group") {
        print("  [\(idx)] '\(nm)'")
    }
}
