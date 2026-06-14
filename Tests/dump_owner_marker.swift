// Test the "owner marker" hypothesis:
// Each sentinel section's first 0x104f with tl==SENTINEL (relOff==0) and byte18==0x01
// is an owner tag — clipIdx identifies which compound owns this sentinel.
// Remaining 0x104f entries (relOff > 0) are the actual constituents.
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

struct Blk { let ct: UInt16; let off: Int; let sz: Int }
var blocks: [Blk] = []
var ii = 0x1f; while ii+9 <= n {
    guard b(ii)==0x5a else { ii+=1; continue }
    let sz=Int(u32le(ii+3)); let ct=u16le(ii+7)
    guard sz>0, sz<50_000_000, ii+9+sz<=n else { ii+=1; continue }
    blocks.append(Blk(ct:ct, off:ii+9, sz:sz)); ii += 1
}

let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }
let all2629 = blocks.filter { $0.ct == 0x2629 }.sorted { $0.off < $1.off }
let all262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }

// Build combined pool (0x2629 + 0x262b sorted by offset)
struct PoolEntry { let ct: UInt16; let off: Int; let sz: Int; var name: String = ""; var lengthSamples: Int64 = 0 }
var combined: [PoolEntry] = []
for blk in all2629 { combined.append(PoolEntry(ct: blk.ct, off: blk.off, sz: blk.sz)) }
for blk in all262b { combined.append(PoolEntry(ct: blk.ct, off: blk.off, sz: blk.sz)) }
combined.sort { $0.off < $1.off }

func getName(_ pOff: Int, _ pEnd: Int) -> String {
    guard let nb = all2628.first(where: { $0.off >= pOff && $0.off+$0.sz <= pEnd }) else { return "<noname>" }
    let nl = Int(u32le(nb.off))
    guard nl >= 1, nl <= 512, nb.off+4+nl <= n,
          let name = String(bytes: d[nb.off+4..<nb.off+4+nl], encoding: .utf8) else { return "<bad>" }
    return name
}

for i in 0..<combined.count {
    let pEnd = combined[i].off + combined[i].sz
    combined[i].name = getName(combined[i].off, pEnd)
    if combined[i].ct == 0x262b {
        // lengthSamples is at offset 8 inside the 0x262b content (after some header bytes)
        // Check inside the 0x2628 child block for the compound length
        if let nb = all2628.first(where: { $0.off >= combined[i].off && $0.off+$0.sz <= pEnd }) {
            // The 0x2628 name block: [u32 nameLen][name bytes][padding...][u64 lengthSamples?]
            let nl = Int(u32le(nb.off))
            let afterName = nb.off + 4 + nl
            // Try to read length from 0x262b content directly at offset 8
            if combined[i].off + 16 <= n {
                // First 8 bytes of 0x262b content might be start/length
                let v0 = u64le(combined[i].off)
                let v8 = u64le(combined[i].off + 8)
                _ = afterName; _ = v0; _ = v8
            }
        }
    }
}

print("Combined pool (\(combined.count) entries):")
for (i, e) in combined.enumerated() {
    let type = e.ct == 0x2629 ? "audio" : "cmpd"
    print("  combined[\(i)] \(type) '\(e.name)'")
}

// Sentinel sections
let all1054 = blocks.filter { $0.ct == 0x1054 }.sorted { $0.off < $1.off }
guard all1054.count >= 2 else { print("Need 2x 0x1054"); exit(0) }
let s1054 = all1054[1]
let sStart = s1054.off, sEnd = s1054.off + s1054.sz
let inner1054Ranges = blocks.filter { $0.ct == 0x1054 && $0.off > sStart && $0.off+$0.sz <= sEnd }.map { ($0.off, $0.off+$0.sz) }
let sentinel1052s = blocks.filter { blk in
    guard blk.ct == 0x1052, blk.off >= sStart, blk.off+blk.sz <= sEnd else { return false }
    return !inner1054Ranges.contains { r in r.0 <= blk.off && blk.off+blk.sz <= r.1 }
}.sorted { $0.off < $1.off }

let SENTINEL: UInt64 = 1_000_000_000_000

print("\n\(sentinel1052s.count) sentinel sections, \(all262b.count) compounds")

// Build compound→sentinels mapping using owner markers
var compoundToSentinels: [Int: [Int]] = [:]  // compoundIdx → [sentinelOrdinals]
var sentinelOwners: [Int: Int] = [:]          // sentinelOrdinal → compoundIdx (in combined pool)

print("\n=== Owner markers per sentinel ===")
for (ord, sec) in sentinel1052s.enumerated() {
    let secEnd = sec.off + sec.sz
    let refs = blocks.filter { $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd }.sorted { $0.off < $1.off }

    var ownerIdx: Int? = nil
    var ownerName: String = ""
    var constituentCount = 0

    for r in refs {
        guard r.sz >= 19 else { continue }
        let clipIdx = Int(u16le(r.off + 2))
        let tl = u64le(r.off + 7)
        let byte18 = b(r.off + 18)

        if tl == SENTINEL && byte18 == 0x01 {
            // Owner marker: clipIdx → compound in combined pool
            if ownerIdx == nil {
                ownerIdx = clipIdx
                ownerName = clipIdx < combined.count ? combined[clipIdx].name : "<oob:\(clipIdx)>"
            }
        } else if tl > SENTINEL {
            constituentCount += 1
        }
    }

    if let oi = ownerIdx {
        sentinelOwners[ord] = oi
        compoundToSentinels[oi, default: []].append(ord)
        print("  sent[\(ord)] → combined[\(oi)] '\(ownerName)' (\(constituentCount) constituents)")
    } else {
        print("  sent[\(ord)] → NO OWNER MARKER (\(constituentCount) constituents, refs=\(refs.count))")
        // Dump all entries for debugging
        for r in refs.prefix(5) {
            guard r.sz >= 19 else { continue }
            let clipIdx = Int(u16le(r.off + 2))
            let tl = u64le(r.off + 7)
            let byte18 = b(r.off + 18)
            let name = clipIdx < combined.count ? combined[clipIdx].name : "<oob>"
            print("    clipIdx=\(clipIdx) '\(name)' tl=\(tl) byte18=0x\(String(format:"%02x",byte18))")
        }
    }
}

// Now show compound→sentinels mapping
print("\n=== Compound → Sentinel mapping ===")
for ci in 0..<combined.count {
    guard combined[ci].ct == 0x262b else { continue }
    let sents = compoundToSentinels[ci] ?? []
    print("  combined[\(ci)] '\(combined[ci].name)': \(sents.isEmpty ? "NO SENTINELS" : "sentinels=\(sents)")")
}

// For each sentinel, show constituents using owner-marker mapping
print("\n=== Constituent clips per sentinel (with owner context) ===")
for (ord, sec) in sentinel1052s.enumerated() {
    let secEnd = sec.off + sec.sz
    let refs = blocks.filter { $0.ct == 0x104f && $0.off >= sec.off && $0.off+$0.sz <= secEnd }.sorted { $0.off < $1.off }
    let ownerName = sentinelOwners[ord].map { combined[$0].name } ?? "<unowned>"

    var constituents: [(clipIdx: Int, name: String, relOff: Int64, byte18: UInt8)] = []
    for r in refs {
        guard r.sz >= 19 else { continue }
        let clipIdx = Int(u16le(r.off + 2))
        let tl = u64le(r.off + 7)
        let byte18 = b(r.off + 18)
        guard tl > SENTINEL else { continue }  // skip owner markers and below-sentinel entries
        let relOff = Int64(bitPattern: tl - SENTINEL)
        let name = clipIdx < combined.count ? combined[clipIdx].name : "<oob:\(clipIdx)>"
        constituents.append((clipIdx: clipIdx, name: name, relOff: relOff, byte18: byte18))
    }

    if !constituents.isEmpty {
        print("  sent[\(ord)] (owns '\(ownerName)'): \(constituents.count) constituents")
        for c in constituents.prefix(5) {
            let typeStr = c.clipIdx < combined.count ? (combined[c.clipIdx].ct == 0x262b ? "[cmpd]" : "[audio]") : "[oob]"
            print("    clipIdx=\(c.clipIdx)\(typeStr) '\(c.name)' relOff=\(c.relOff) byte18=0x\(String(format:"%02x",c.byte18))")
        }
        if constituents.count > 5 { print("    ... \(constituents.count-5) more") }
    }
}
