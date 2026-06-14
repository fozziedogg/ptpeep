import Foundation

guard CommandLine.arguments.count > 1 else { print("Usage: \(CommandLine.arguments[0]) <file.ptx>"); exit(1) }
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let n = raw.count

// Rolling XOR decode
let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
for i: UInt16 in 0...255 {
    if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
}
var table = [UInt8](repeating: 0, count: 256)
for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
var d = raw; let src = Array(raw)
d.withUnsafeMutableBytes { dst in
    let dp = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
    var off = 4096
    while off < n {
        let xb = table[(off >> 12) & 0xff]
        if xb != 0 { let e = min(off+4096,n); for j in off..<e { dp[j]=src[j]^xb } }
        off += 4096
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
    var i = 0x1f
    while i+9 <= n {
        guard b(i)==0x5a else { i+=1; continue }
        let sz=Int(u32le(i+3)); let ct=u16le(i+7)
        guard sz>0, sz<50_000_000, i+9+sz<=n else { i+=1; continue }
        blocks.append(Blk(ct:ct, off:i+9, sz:sz))
        i += 1
    }
}

// ── 1. Audio pool (0x2629 → 0x2628 children) ─────────────────────────────
print("=== Audio pool (0x2629 → 0x2628) ===")
let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
var audioPool: [(idx: Int, name: String)] = []
for (pi, parent) in all2629.enumerated() {
    let pEnd = parent.off + parent.sz
    let children = all2628.filter { $0.off >= parent.off && $0.off+$0.sz <= pEnd }
    for child in children {
        let pos = child.off
        guard pos+4 < n else { continue }
        let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { continue }
        let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<?"
        print("  audio[\(pi)] '\(name)'")
        audioPool.append((pi, name))
        break  // first child per parent = identity
    }
}

// ── 2. Compound pool (0x262b → 0x2628 children) ──────────────────────────
print("\n=== Compound pool (0x262b → 0x2628) ===")
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
var compoundPool: [(idx: Int, name: String, start: Int64)] = []
for (pi, parent) in all262b.enumerated() {
    let pEnd = parent.off + parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else { continue }
    let pos = child.off
    guard pos+4 < n else { continue }
    let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { continue }
    let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<?"
    let tp = pos+4+nl; guard tp+5 <= n else { continue }
    let nSrcOff = Int((b(tp+1) & 0xf0) >> 4)
    let nLength  = Int((b(tp+2) & 0xf0) >> 4)
    let nStart   = Int((b(tp+3) & 0xf0) >> 4)
    guard tp+5+nSrcOff+nLength+nStart <= n else { continue }
    let startVal = readLE(tp+5+nSrcOff+nLength, nStart)
    print("  compound[\(pi)] '\(name)' start=\(Int64(bitPattern: startVal))")
    compoundPool.append((pi, name, Int64(bitPattern: startVal)))
}

// ── 3. Sentinel sections ──────────────────────────────────────────────────
print("\n=== Sentinel 0x1052 sections ===")
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
guard all1054.count >= 2 else { print("Need >=2 0x1054"); exit(0) }
let sent = all1054[1]; let sStart=sent.off, sEnd=sent.off+sent.sz
let sent1052s = blocks.filter {
    $0.ct==0x1052 && $0.off>=sStart && $0.off+$0.sz<=sEnd
}.sorted { $0.off < $1.off }
print("Sentinel sections: \(sent1052s.count)")

let SENTINEL: Int64 = 1_000_000_000_000

for (si, sec) in sent1052s.prefix(5).enumerated() {
    let secEnd = sec.off + sec.sz
    let placements = blocks.filter {
        $0.ct==0x104f && $0.off>=sec.off && $0.off+$0.sz<=secEnd
    }.sorted { $0.off < $1.off }

    guard !placements.isEmpty else { continue }
    print("\nSentinel[\(si)] (→ compound pool entry \(si): '\(si < compoundPool.count ? compoundPool[si].name : "?")')")
    print("  \(placements.count) constituent placements:")

    for (pi, pl) in placements.enumerated() {
        guard pl.sz >= 15 else { continue }
        let clipIdx16 = Int(u16le(pl.off+2))
        let tl = Int64(bitPattern: u64le(pl.off+7))
        let relOff = tl - SENTINEL
        // Show what each candidate pool resolves to
        let audioName  = clipIdx16 < audioPool.count    ? audioPool[clipIdx16].name    : "OUT OF RANGE"
        let compName   = clipIdx16 < compoundPool.count ? compoundPool[clipIdx16].name : "OUT OF RANGE"
        print("  [\(pi)] clipIdx=\(clipIdx16) relOffset=\(relOff)")
        print("       → as audio pool:    '\(audioName)'")
        print("       → as compound pool: '\(compName)'")
        // Also show raw bytes around the clipIdx field for sanity
        let rawBytes = (0..<min(pl.sz, 20)).map { String(format:"%02x", b(pl.off+$0)) }.joined(separator:" ")
        print("       raw[0..19]: \(rawBytes)")
    }
}
