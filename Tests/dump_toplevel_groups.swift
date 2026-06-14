// Find top-level multi-track group records by searching for known group names.
// Group-183 contains 1 split.grp-06 (idx 415), 2 split.grp-04 (idx 416)
// Group-70  contains 3 split.grp-03 (idx 89),  4 split.grp-02 (idx 90), 5 split.grp-01
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

// Search for the strings "Group-183" and "Group-70" in the decoded file
let targets = ["Group-183", "Group-70", "Group-"]
for target in targets.prefix(2) {
    let bytes = Array(target.utf8)
    let blen = bytes.count
    print("\n=== Searching for '\(target)' ===")
    for off in 0..<(n-blen) {
        guard d[off] == bytes[0] else { continue }
        guard d[off..<off+blen].elementsEqual(bytes) else { continue }
        // Found — what block contains this?
        let enclosing = blocks.filter { $0.off <= off && off < $0.off+$0.sz }
        let closest = enclosing.max(by: { $0.off < $1.off })
        let ctStr = closest.map { "0x\(String($0.ct, radix:16))" } ?? "no-block"
        let relOff = closest.map { off - $0.off } ?? -1
        // Print context: 8 bytes before and 32 after
        let ctx = (max(0,off-8)..<min(n,off+32)).map { String(format:"%02x",d[$0]) }.joined(separator:" ")
        print("  file:0x\(String(off,radix:16)) in \(ctStr)+\(relOff): \(ctx)")
        // Try reading as length-prefixed string (4-byte LE length before)
        if off >= 4 {
            let possibleLen = Int(u32le(off-4))
            if possibleLen == blen || possibleLen == blen+1 {
                print("    ^ preceded by u32=\(possibleLen) — looks like length-prefixed string!")
            }
        }
    }
}

// Also scan all block types present and look for any we haven't explored
// that appear near the 0x262b blocks (compound pool area)
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
guard let first262b = all262b.first, let last262b = all262b.last else { print("No 0x262b"); exit(0) }
print("\n0x262b range: file:0x\(String(first262b.off,radix:16)) to 0x\(String(last262b.off+last262b.sz,radix:16))")

// What other block types appear in a ±2MB window around the 262b pool?
let window = (first262b.off - 500_000)...(last262b.off + 500_000)
let nearbyTypes = Set(blocks.filter { window.contains($0.off) && $0.ct != 0x262b && $0.ct != 0x2628 }.map { $0.ct })
print("Nearby block types (not 0x262b/0x2628): \(nearbyTypes.sorted().map { "0x\(String($0,radix:16))" }.joined(separator:", "))")

// Specifically look for 0x262c, 0x262d, 0x262e — likely candidates for parent structure
for targetCT: UInt16 in [0x262c, 0x262d, 0x262e, 0x2630, 0x2632, 0x2634, 0x2637] {
    let matches = blocks.filter { $0.ct == targetCT }
    guard !matches.isEmpty else { continue }
    print("\n0x\(String(targetCT, radix:16)) blocks: \(matches.count)")
    for m in matches.prefix(5) {
        // Try to read name at start
        guard m.sz >= 4 else { continue }
        let nl = Int(u32le(m.off))
        var name = "<no name>"
        if nl > 0, nl <= 512, m.off+4+nl <= n,
           let s = String(bytes: d[m.off+4..<m.off+4+nl], encoding: .utf8) {
            name = s
        }
        let preview = (0..<min(32,m.sz)).map { String(format:"%02x",b(m.off+$0)) }.joined(separator:" ")
        print("  file:0x\(String(m.off,radix:16)) sz=\(m.sz) name='\(name)' bytes: \(preview)")
    }
}
