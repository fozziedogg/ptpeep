// Dump 0x2423 block structure — this is where multi-track group names live
// "Group-183" and "Group-70" found here. Want to see how they reference per-track clip groups.
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

// Read a name at pos (u32 length-prefixed)
func readName(_ pos: Int) -> (name: String, end: Int)? {
    guard pos+4 <= n else { return nil }
    let nl = Int(u32le(pos))
    guard nl > 0, nl <= 1024, pos+4+nl <= n else { return nil }
    guard let s = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) else { return nil }
    return (s, pos+4+nl)
}

let all2423 = blocks.filter { $0.ct == 0x2423 }.sorted { $0.off < $1.off }
print("Total 0x2423 blocks: \(all2423.count)")

// Build parent/child relationships: a 0x2423 is a child if it's contained within another 0x2423
func isChild(_ blk: Blk) -> Bool {
    all2423.contains { p in p.off != blk.off && p.off <= blk.off && blk.off+blk.sz <= p.off+p.sz }
}

let topLevel = all2423.filter { !isChild($0) }
let children = all2423.filter { isChild($0) }
print("Top-level: \(topLevel.count)  Children: \(children.count)")

// Focus on the two we care about — find them by name content
print("\n--- All 0x2423 blocks with names (first 4 bytes + name) ---")
for blk in all2423 {
    let tag = u32le(blk.off)  // first 4 bytes — type tag?
    guard let (name, afterName) = readName(blk.off + 4) else { continue }
    guard name.contains("Group") || name.contains("split") || name.contains("grp") else { continue }
    let depth = isChild(blk) ? "  child" : "TOP"
    // Show what comes immediately after the name
    let afterBytes = (afterName..<min(afterName+20, blk.off+blk.sz)).map { String(format:"%02x",b($0)) }.joined(separator:" ")
    print("\(depth) tag=0x\(String(tag,radix:16)) name='\(name)' afterName: \(afterBytes)")
    // Look for child 0x2423 blocks inside this one
    let myChildren = children.filter { $0.off >= blk.off && $0.off+$0.sz <= blk.off+blk.sz }
    for c in myChildren {
        let ctag = u32le(c.off)
        if let (cname, _) = readName(c.off + 4) {
            print("    child tag=0x\(String(ctag,radix:16)) name='\(cname)'")
        }
    }
}

// Now specifically dump Group-183 and Group-70 in full
print("\n--- Full dump of Group-183 and Group-70 blocks ---")
for targetName in ["Group-183", "Group-70"] {
    guard let blk = all2423.first(where: { b in
        guard let (nm,_) = readName(b.off+4) else { return false }
        return nm == targetName
    }) else { print("'\(targetName)' not found"); continue }

    print("\n'\(targetName)' at file:0x\(String(blk.off,radix:16)) sz=\(blk.sz)")
    let fullBytes = (blk.off..<min(blk.off+blk.sz, blk.off+256)).map { String(format:"%02x",b($0)) }
    // Print in rows of 16
    for row in stride(from: 0, to: fullBytes.count, by: 16) {
        let hex = fullBytes[row..<min(row+16,fullBytes.count)].joined(separator:" ")
        print("  +\(String(format:"%03d",row)): \(hex)")
    }
}
