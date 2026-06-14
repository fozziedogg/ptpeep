import Foundation

// Find clip group definitions in .ptx binary.
// Search for "Group-" strings and show surrounding block context.
// Also look for any block type that could be a clip group container.

guard CommandLine.arguments.count > 1 else { print("Usage: dump_clip_groups <file.ptx>"); exit(1) }
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    print("Cannot read file"); exit(1)
}
let n = raw.count

// XOR decode
let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
for i: UInt16 in 0...255 {
    if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
}
var table = [UInt8](repeating: 0, count: 256)
for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
var d = raw
d.withUnsafeMutableBytes { dst in
    raw.withUnsafeBytes { src in
        let dPtr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let sPtr = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var off = 4096
        while off < n {
            let xorByte = table[(off >> 12) & 0xff]
            if xorByte != 0 { let end = min(off+4096, n); for j in off..<end { dPtr[j] = sPtr[j] ^ xorByte } }
            off += 4096
        }
    }
}

func b(_ i: Int) -> UInt8 { d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in p[i] } }
func u16le(_ i: Int) -> UInt16 { UInt16(b(i)) | UInt16(b(i+1))<<8 }
func u32le(_ i: Int) -> UInt32 { UInt32(b(i)) | UInt32(b(i+1))<<8 | UInt32(b(i+2))<<16 | UInt32(b(i+3))<<24 }
func hex(_ i: Int, _ c: Int) -> String { (0..<min(c,n-i)).map{String(format:"%02x",b(i+$0))}.joined(separator:" ") }

// Scan all blocks
struct Blk { let bt: UInt16; let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var i = 0x1f
while i + 9 <= n {
    guard b(i) == 0x5a else { i += 1; continue }
    let sz = Int(u32le(i+3))
    let ct = u16le(i+7)
    let bt = u16le(i+1)
    guard sz > 0, sz < 50_000_000, i+9+sz <= n else { i += 1; continue }
    blocks.append(Blk(bt: bt, ct: ct, off: i+9, sz: sz))
    i += 1
}

// ── 1. Find "Group-" strings in the decoded data ──────────────────────────────
print("=== Searching for 'Group-' strings ===")
let needle = Array("Group-".utf8)
var searchPos = 0
var groupStrings: [(Int, String)] = []
while searchPos + needle.count <= n {
    var match = true
    for k in 0..<needle.count { if b(searchPos+k) != needle[k] { match = false; break } }
    if match {
        // Read full string (stop at null or non-ASCII)
        var end = searchPos
        while end < n && b(end) >= 0x20 && b(end) < 0x80 { end += 1 }
        if let s = String(bytes: d[searchPos..<end], encoding: .utf8) {
            groupStrings.append((searchPos, s))
        }
    }
    searchPos += 1
}
print("Found \(groupStrings.count) 'Group-' string occurrences")
for (pos, s) in groupStrings.prefix(20) {
    print("  @\(pos): '\(s)'")
    // Show bytes before the string to find length prefix
    if pos >= 4 { print("    len-prefix bytes: \(hex(pos-4, 4)) → u32=\(u32le(pos-4))") }
    // Show bytes 8 before for block header context
    if pos >= 10 { print("    context-10: \(hex(pos-10, min(10+s.count+4, 40)))") }
}

// ── 2. For each "Group-" string, find which block contains it ─────────────────
print("\n=== Block containing each 'Group-' string ===")
for (pos, s) in groupStrings.prefix(10) {
    // Find innermost block whose data range contains pos
    var best: Blk? = nil
    var bestSz = Int.max
    for blk in blocks {
        if blk.off <= pos && pos < blk.off + blk.sz && blk.sz < bestSz {
            best = blk; bestSz = blk.sz
        }
    }
    if let blk = best {
        print("  '\(s)' @\(pos) → block ct=0x\(String(format:"%04x",blk.ct)) bt=0x\(String(format:"%04x",blk.bt)) dataOff=\(blk.off) sz=\(blk.sz)")
        // Show the first 48 bytes of the block
        print("    block data: \(hex(blk.off, min(48, blk.sz)))")
    } else {
        print("  '\(s)' @\(pos) → no containing block found")
    }
}

// ── 3. Look for 0x2625/0x2626 blocks (near clip pool, might be groups) ────────
print("\n=== 0x2625 blocks (first 5) ===")
for blk in blocks.filter({ $0.ct == 0x2625 }).prefix(5) {
    print("  dataOff=\(blk.off) sz=\(blk.sz)")
    print("  data: \(hex(blk.off, min(64, blk.sz)))")
    // Try to read a length-prefixed name
    if blk.sz >= 4 {
        let nl = Int(u32le(blk.off))
        if nl > 0, nl <= 256, blk.off+4+nl <= n {
            if let nm = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
                print("  name: '\(nm)'")
            }
        }
    }
}

print("\n=== 0x2626 blocks (first 5) ===")
for blk in blocks.filter({ $0.ct == 0x2626 }).prefix(5) {
    print("  dataOff=\(blk.off) sz=\(blk.sz)")
    print("  data: \(hex(blk.off, min(64, blk.sz)))")
    if blk.sz >= 4 {
        let nl = Int(u32le(blk.off))
        if nl > 0, nl <= 256, blk.off+4+nl <= n {
            if let nm = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
                print("  name: '\(nm)'")
            }
        }
    }
}

// ── 4. Look at 0x2037 blocks (large count=2113, might be compound regions) ────
print("\n=== 0x2037 blocks (first 3) ===")
for blk in blocks.filter({ $0.ct == 0x2037 }).prefix(3) {
    print("  dataOff=\(blk.off) sz=\(blk.sz)")
    print("  data: \(hex(blk.off, min(64, blk.sz)))")
    if blk.sz >= 4 {
        let nl = Int(u32le(blk.off))
        if nl > 0, nl <= 256, blk.off+4+nl <= n {
            if let nm = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) {
                print("  name: '\(nm)'")
            }
        }
    }
}

// ── 5. Specifically find "Group-06" and its timeline position ─────────────────
print("\n=== Looking for 'Group-06' specifically ===")
let g06 = groupStrings.filter { $0.1.hasPrefix("Group-06") }
print("'Group-06' occurrences: \(g06.count)")
for (pos, s) in g06 {
    print("  '\(s)' @\(pos)")
    // Show wider context
    let ctxStart = max(0, pos-16)
    print("  wide context: \(hex(ctxStart, min(s.count+32, 80)))")
}

// ── 6. Check if 0x2628 (clip pool child) has entries with group names ─────────
print("\n=== 0x2628 blocks whose name contains 'Group' (first 5) ===")
var groupClipCount = 0
for blk in blocks.filter({ $0.ct == 0x2628 }) {
    guard blk.sz >= 4 else { continue }
    let nl = Int(u32le(blk.off))
    guard nl > 0, nl <= 512, blk.off+4+nl <= n else { continue }
    guard let nm = String(bytes: d[blk.off+4..<blk.off+4+nl], encoding: .utf8) else { continue }
    if nm.contains("Group") {
        groupClipCount += 1
        if groupClipCount <= 5 {
            print("  '\(nm)' dataOff=\(blk.off) sz=\(blk.sz)")
            print("  data: \(hex(blk.off, min(blk.sz, 48)))")
        }
    }
}
print("Total 0x2628 blocks with 'Group' in name: \(groupClipCount)")
