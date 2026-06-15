// Search for known clip positions anywhere in the decoded file.
// Uses ClipGroup_PeepTest (grouped) + known positions from ClipGroup_PeepTestExposed.
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
print("Total blocks: \(blocks.count)")

// Known positions from ClipGroup_PeepTestExposed.txt (23.976fps @ 48k)
// 01:00:00:00 = 172972800; +10s = 173452800; +20s = 173932800
// Known-correct positions from PeepTestC (ungrouped). Also include sentinel (wrong) values.
let targets: [(Int64, String)] = [
    // Actual current clip positions (from PeepTestC ungrouped):
    (188952370, "1-split actual clip pos"),
    (188987345, "2-split actual clip #1 pos"),
    (188998810, "2-split actual clip #2 pos"),
    (189002814, "2-split actual clip #3 pos"),
    (189084896, "2-split actual clip #4 pos"),
    (189215026, "3-split actual clip pos"),
    (189297634, "3-split actual clip #2 pos"),
    (188911879, "4-split actual clip pos"),
    // Sentinel (wrong) values for comparison — where do THESE live?
    (188885472, "sentinel value (WRONG — all 4 groups point here)"),
]

for (val, label) in targets {
    print("\n=== \(val) (\(label)) ===")
    let b8: [UInt8] = (0..<8).map { UInt8((UInt64(bitPattern: val) >> ($0*8)) & 0xff) }
    let b4: [UInt8] = (0..<4).map { UInt8((UInt64(bitPattern: val) >> ($0*8)) & 0xff) }

    var found8 = false
    for off in 0..<(n-8) {
        guard d[off] == b8[0] else { continue }
        guard d[off..<off+8].elementsEqual(b8) else { continue }
        found8 = true
        // Find enclosing block
        let blk = blocks.last(where: { $0.off <= off && off < $0.off+$0.sz })
        let ctStr = blk.map { "0x\(String($0.ct, radix:16))" } ?? "no-block"
        let relOff = blk.map { off - $0.off } ?? -1
        // Print 16 bytes of context around the match
        let ctx = (max(0,off-4)..<min(n,off+12)).map { String(format:"%02x",d[$0]) }.joined(separator:" ")
        print("  int64 @ file:0x\(String(off,radix:16)) block:\(ctStr)+\(relOff)  [\(ctx)]")
    }

    // 4-byte hits not already covered
    for off in 0..<(n-4) {
        guard d[off] == b4[0] else { continue }
        guard d[off..<off+4].elementsEqual(b4) else { continue }
        // Skip if covered by 8-byte hit
        let b8match = off >= 8 ? false : false  // check: is this inside an 8-byte hit?
        let b8_lo = b8.prefix(4)
        if b8.prefix(4).elementsEqual(b4) {
            // val fits in 4 bytes — skip if the next 4 bytes are 00 00 00 00 (int64 match already shown)
            if off+8 <= n && d[off+4..<off+8].allSatisfy({ $0 == 0 }) { continue }
        }
        let blk = blocks.last(where: { $0.off <= off && off < $0.off+$0.sz })
        let ctStr = blk.map { "0x\(String($0.ct, radix:16))" } ?? "no-block"
        let relOff = blk.map { off - $0.off } ?? -1
        let ctx = (max(0,off-4)..<min(n,off+8)).map { String(format:"%02x",d[$0]) }.joined(separator:" ")
        print("  int32 @ file:0x\(String(off,radix:16)) block:\(ctStr)+\(relOff)  [\(ctx)]")
    }
    if !found8 { print("  (no int64 matches)") }
}
print("\nAll block types present: \(Set(blocks.map{$0.ct}).sorted().map{"0x\(String($0,radix:16))"}.joined(separator:", "))")
