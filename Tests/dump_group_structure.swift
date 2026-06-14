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

let SENTINEL: Int64 = 1_000_000_000_000

// ── 0x1054 containers ────────────────────────────────────────────────────────
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
print("=== 0x1054 blocks: \(all1054.count) ===")
for (i, blk) in all1054.enumerated() {
    print("  [\(i)] off=\(blk.off) sz=\(blk.sz) end=\(blk.off+blk.sz)")
}

// ── 0x1052 sections inside each 0x1054 ──────────────────────────────────────
let all1052 = blocks.filter { $0.ct == 0x1052 }.sorted { $0.off < $1.off }
let all104f = blocks.filter { $0.ct == 0x104f }.sorted { $0.off < $1.off }

for (ti, t54) in all1054.enumerated() {
    let t54End = t54.off + t54.sz
    let sections = all1052.filter { $0.off >= t54.off && $0.off+$0.sz <= t54End }
    print("\n── 0x1054[\(ti)] at off=\(t54.off): \(sections.count) 0x1052 sections ──")
    for (si, sec) in sections.enumerated() {
        let secEnd = sec.off + sec.sz
        let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }
        let sentinelCount = placements.filter { pl -> Bool in
            guard pl.sz >= 15 else { return false }
            let tl = Int64(bitPattern: u64le(pl.off+7))
            return tl >= SENTINEL
        }.count
        // Try to read track name from 0x1052
        var trackName = "<no name>"
        if sec.sz >= 4 {
            let nl = Int(u32le(sec.off))
            if nl > 0, nl <= 256, sec.off+4+nl <= n {
                trackName = String(bytes: d[sec.off+4..<sec.off+4+nl], encoding: .utf8) ?? "<utf8?>"
            } else if nl == 0 {
                trackName = "<nameless>"
            }
        }
        print("  sec[\(si)] '\(trackName)' off=\(sec.off) sz=\(sec.sz) placements=\(placements.count) sentinelTL=\(sentinelCount)")
    }
}

// ── Compound pool (0x262b) ───────────────────────────────────────────────────
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
print("\n=== Compound pool: \(all262b.count) 0x262b entries ===")
for (pi, parent) in all262b.enumerated() {
    let pEnd = parent.off + parent.sz
    guard let child = all2628.first(where: { $0.off >= parent.off && $0.off+$0.sz <= pEnd }) else {
        print("  [\(pi)] <no 0x2628 child>"); continue
    }
    let pos = child.off
    guard pos+4 < n else { continue }
    let nl = Int(u32le(pos)); guard nl>0, nl<=512, pos+4+nl<=n else { print("  [\(pi)] <bad nameLen \(u32le(pos))>"); continue }
    let name = String(bytes: d[pos+4..<pos+4+nl], encoding: .utf8) ?? "<?"
    print("  [\(pi)] '\(name)'")
}

// ── Track playlist placements with isGroup (b18==0x01) ──────────────────────
print("\n=== Group placements in track playlists ===")
guard let firstT54 = all1054.first else { print("No 0x1054"); exit(0) }
let ft54End = firstT54.off + firstT54.sz
let trackSections = all1052.filter { $0.off >= firstT54.off && $0.off+$0.sz <= ft54End }
for sec in trackSections {
    let secEnd = sec.off + sec.sz
    let nl = sec.sz >= 4 ? Int(u32le(sec.off)) : 0
    let name = (nl > 0 && nl <= 256 && sec.off+4+nl <= n)
        ? (String(bytes: d[sec.off+4..<sec.off+4+nl], encoding: .utf8) ?? "?") : "<>"
    let placements = all104f.filter { $0.off >= sec.off && $0.off+$0.sz <= secEnd }
    for pl in placements {
        guard pl.sz >= 19 else { continue }
        let b18 = b(pl.off+18)
        guard b18 == 0x01 else { continue }
        let clipIdx = Int(u16le(pl.off+2))
        let tl = Int64(bitPattern: u64le(pl.off+7))
        print("  track='\(name)' clipIdx=\(clipIdx) tl=\(tl) (compound pool entry → '\(clipIdx < all262b.count ? "entry[\(clipIdx)]" : "OUT")')")
    }
}
