import Foundation

// Find the block type that maps group placements to group names.
// Known facts:
//   - Group-06 is at 1:28:45:19 (255,893,638 samples) on 1 src and 4 src
//   - Group-06 has 0x2423 ordinal 156 (0x9c)
//   - 0x104f placements with byte9=0x01 reference underlying audio clips, not the group name
//
// Strategy: look at 0x262b (570 entries) and 0x2627 (114 entries),
// and search for timeline position 255,893,638 in any block type.

guard CommandLine.arguments.count > 1 else { print("need ptx"); exit(1) }
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let n = raw.count

let xv = raw[0x13]; var delta: UInt8 = 0
for i: UInt16 in 0...255 {
    if (i * 11) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
}
var tbl = [UInt8](repeating: 0, count: 256)
for i in 0..<256 { tbl[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
var d = raw
d.withUnsafeMutableBytes { dst in
    raw.withUnsafeBytes { src in
        let dp = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let sp = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var o = 4096
        while o < n {
            let xb = tbl[(o >> 12) & 0xff]
            if xb != 0 { let e=min(o+4096,n); for j in o..<e { dp[j]=sp[j]^xb } }
            o += 4096
        }
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func hex(_ i: Int, _ c: Int) -> String { (0..<min(c,n-i)).map{String(format:"%02x",b(i+$0))}.joined(separator:" ") }

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var i = 0x1f
while i+9 <= n {
    guard b(i)==0x5a else { i+=1; continue }
    let sz=Int(u32le(i+3)); let ct=u16le(i+7)
    guard sz>0, sz<50_000_000, i+9+sz<=n else { i+=1; continue }
    blocks.append(Blk(ct:ct, off:i+9, sz:sz))
    i += 1
}

// ── 1. Scan for the 4-byte LE representation of 255,893,638 = 0x0F40A086 ──────
let targetBytes: [UInt8] = [0x86, 0xa0, 0x40, 0x0f]
print("=== Blocks containing timeline position 255,893,638 (0x0f40a086) ===")
var searchPos = 0
var hitBlocks: Set<Int> = []
while searchPos + 4 <= n {
    if b(searchPos) == targetBytes[0] && b(searchPos+1) == targetBytes[1] &&
       b(searchPos+2) == targetBytes[2] && b(searchPos+3) == targetBytes[3] {
        // Find innermost containing block
        var best: Blk? = nil; var bestSz = Int.max
        for blk in blocks {
            if blk.off <= searchPos && searchPos+4 <= blk.off+blk.sz && blk.sz < bestSz {
                best = blk; bestSz = blk.sz
            }
        }
        if let blk = best, !hitBlocks.contains(blk.off) {
            hitBlocks.insert(blk.off)
            print("  ct=0x\(String(format:"%04x",blk.ct)) off=\(blk.off) sz=\(blk.sz) (value at \(searchPos), offset+\(searchPos-blk.off))")
            print("  data: \(hex(blk.off, min(blk.sz, 64)))")
            // Try length-prefixed name
            if blk.sz >= 4 {
                let nl = Int(u32le(blk.off))
                if nl > 0, nl <= 256, blk.off+4+nl <= n,
                   let s = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
                    print("  → name: '\(s)'")
                }
            }
        }
    }
    searchPos += 1
}

// ── 2. Examine 0x262b blocks (first 10) ───────────────────────────────────────
print("\n=== 0x262b blocks (first 10) ===")
for blk in blocks.filter({ $0.ct==0x262b }).prefix(10) {
    print("  off=\(blk.off) sz=\(blk.sz)")
    print("  data: \(hex(blk.off, min(blk.sz, 64)))")
    if blk.sz >= 4 {
        let nl = Int(u32le(blk.off))
        if nl > 0, nl <= 256, blk.off+4+nl <= n,
           let s = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
            print("  → name: '\(s)'")
        }
    }
}

// ── 3. Examine 0x2627 blocks (first 10) ───────────────────────────────────────
print("\n=== 0x2627 blocks (first 10) ===")
for blk in blocks.filter({ $0.ct==0x2627 }).prefix(10) {
    print("  off=\(blk.off) sz=\(blk.sz)")
    print("  data: \(hex(blk.off, min(blk.sz, 64)))")
    if blk.sz >= 4 {
        let nl = Int(u32le(blk.off))
        if nl > 0, nl <= 256, blk.off+4+nl <= n,
           let s = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
            print("  → name: '\(s)'")
        }
    }
}

// ── 4. Scan 0x2628 blocks for group names (like "Group-06") ───────────────────
print("\n=== 0x2628 blocks whose name looks like 'Group-NN' ===")
let groupPrefix = Array("Group-".utf8)
var count = 0
for blk in blocks.filter({ $0.ct==0x2628 }) {
    guard blk.sz >= 4 else { continue }
    let nl = Int(u32le(blk.off))
    guard nl >= 7, nl <= 30, blk.off+4+nl <= n else { continue }
    let nameBytes = Array(d[blk.off+4..<blk.off+4+nl])
    guard nameBytes.prefix(groupPrefix.count) == groupPrefix.prefix(groupPrefix.count) else { continue }
    // Check if it's a digit after "Group-"
    if nameBytes.count > 6, nameBytes[6] >= 0x30, nameBytes[6] <= 0x39 {
        count += 1
        if count <= 10 {
            let s = String(bytes: nameBytes, encoding: .utf8) ?? "?"
            print("  '\(s)' off=\(blk.off) sz=\(blk.sz)")
            print("  full data: \(hex(blk.off, min(blk.sz, 64)))")
        }
    }
}
print("Total 0x2628 'Group-NN' entries: \(count)")

// ── 5. Find the 0x2423 block for Group-06 and show surrounding blocks ─────────
print("\n=== Blocks immediately around Group-06 0x2423 (ordinal 156) ===")
var g06blk: Blk? = nil
for blk in blocks where blk.ct == 0x2423 {
    guard blk.sz >= 8 else { continue }
    let ordinal = Int(u32le(blk.off))
    guard ordinal == 156 else { continue }
    let nl = Int(u32le(blk.off+4))
    guard nl > 0, nl <= 256, blk.off+8+nl <= n else { continue }
    if let s = String(bytes: d[blk.off+8..<blk.off+8+nl], encoding: .utf8), s == "Group-06" {
        g06blk = blk; break
    }
}
if let g = g06blk {
    print("Group-06 0x2423 at dataOff=\(g.off) sz=\(g.sz)")
    // Show 200 bytes before and after
    let start = max(0, g.off - 9 - 100)
    print("Context (100 bytes before block header):")
    print("  \(hex(start, 200))")
}
