#!/usr/bin/env swift
// sentinel_diag7.swift — Investigate 0x2425 blocks (227 count = unique group slots)
// and cross-reference with 0x2423 group history, 0x2523 creation counters, and sentinels
import Foundation
struct Block { let contentType: UInt16; let dataOffset: Int; let dataSize: Int }
func u16(_ d: Data, at i: Int) -> UInt16 { guard i+2<=d.count else{return 0}; return UInt16(d[i])|(UInt16(d[i+1])<<8) }
func u32(_ d: Data, at i: Int) -> UInt32 { guard i+4<=d.count else{return 0}; return UInt32(d[i])|(UInt32(d[i+1])<<8)|(UInt32(d[i+2])<<16)|(UInt32(d[i+3])<<24) }
func readLE(_ d: Data, at i: Int, count: Int) -> UInt64 { var v:UInt64=0; for k in 0..<count where i+k<d.count{v|=UInt64(d[i+k])<<(k*8)}; return v }
func hexDump(_ d: Data, at o: Int, count c: Int) -> String { let e=min(o+c,d.count); guard o<e else{return""}; return (o..<e).map{String(format:"%02x",d[$0])}.joined(separator:" ") }
func xorDecode(_ raw: Data) -> Data? {
    guard raw.count>0x14 else{return nil}; let ft=raw[0x12],xv=raw[0x13]; let mul:UInt16,neg:Bool
    switch ft{case 0x05:mul=11;neg=true;case 0x01:mul=53;neg=false;default:return nil}
    var delta:UInt8=0; for i:UInt16 in 0...255{if(i*mul)&0xff==UInt16(xv){delta=neg ? UInt8(truncatingIfNeeded:256 &- Int(i)):UInt8(i);break}}
    var tab=[UInt8](repeating:0,count:256); for i in 0..<256{tab[i]=UInt8((UInt16(i)*UInt16(delta))&0xff)}
    var dec=raw
    if ft==0x05{for ch in stride(from:4096,to:raw.count,by:4096){let x=tab[(ch>>12)&0xff];guard x != 0 else{continue};let e=min(ch+4096,raw.count);for i in ch..<e{dec[i]=raw[i]^x}}}
    else{for i in 0..<raw.count{dec[i]=raw[i]^tab[i&0xff]}}; return dec
}
func scanBlocks(_ d: Data) -> [Block] {
    var b=[Block]();var i=0x1f; while i+9<=d.count{guard d[i]==0x5a else{i+=1;continue};let s=Int(u32(d,at:i+3)),c=u16(d,at:i+7)
    guard s>0,s<50_000_000,i+9+s<=d.count else{i+=1;continue};b.append(Block(contentType:c,dataOffset:i+9,dataSize:s));i+=1};return b
}

guard CommandLine.arguments.count>1 else{print("Usage: sentinel_diag7.swift <file.ptx>");exit(1)}
guard let raw=try? Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])) else{print("err");exit(1)}
guard let data=xorDecode(raw) else{print("xor err");exit(1)}
let blocks=scanBlocks(data)

// ── A. Dump all 0x2425 blocks ──
print("══ A. 0x2425 BLOCKS ══")
let b2425 = blocks.filter{$0.contentType==0x2425}.sorted{$0.dataOffset<$1.dataOffset}
print("Count: \(b2425.count)")

// Check sizes - are they uniform?
let sizes = Set(b2425.map{$0.dataSize})
print("Distinct sizes: \(sizes.sorted())")

// Dump first 20, last 5, and entries near key indices
for (i, b) in b2425.enumerated() {
    guard i < 20 || i >= b2425.count - 5 || (i >= 78 && i <= 90) || (i >= 160 && i <= 170) else { continue }
    print("  [\(i)] size=\(b.dataSize) raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 80)))")

    // Try to parse: does it start with a u32 index like 0x2423?
    if b.dataSize >= 4 {
        let v0 = Int(u32(data, at: b.dataOffset))
        let v1 = b.dataSize >= 8 ? Int(u32(data, at: b.dataOffset + 4)) : -1
        print("       u32[0]=\(v0) u32[1]=\(v1)")
    }
}

// ── B. Cross-reference 0x2425 with 0x2423 ──
print("\n══ B. 0x2425 vs 0x2423 CROSS-REFERENCE ══")
let b2423 = blocks.filter{$0.contentType==0x2423}.sorted{$0.dataOffset<$1.dataOffset}
print("0x2423 count: \(b2423.count), 0x2425 count: \(b2425.count)")

// Parse 0x2423 entries for comparison
struct GroupEntry {
    let idx: Int
    let name: String
    let isEmpty: Bool
}
var groupEntries: [GroupEntry] = []
for b in b2423 {
    guard b.dataSize >= 8 else { continue }
    let idx = Int(u32(data, at: b.dataOffset))
    let nl = Int(u32(data, at: b.dataOffset + 4))
    var name = "?"
    if nl > 0, nl < 512, b.dataOffset + 8 + nl <= data.count {
        name = String(bytes: data[b.dataOffset+8..<b.dataOffset+8+nl], encoding: .utf8) ?? "?"
    }
    let trailStart = b.dataOffset + 8 + nl
    let trailLen = b.dataSize - 8 - nl
    let isEmpty = trailLen >= 1 && data[trailStart] == 0xff
    groupEntries.append(GroupEntry(idx: idx, name: name, isEmpty: isEmpty))
}

// Build unique group slot map: idx → last name seen
var slotNames: [Int: String] = [:]
var slotEmpty: [Int: Bool] = [:]
for e in groupEntries {
    slotNames[e.idx] = e.name
    slotEmpty[e.idx] = e.isEmpty
}
let uniqueSlots = slotNames.keys.sorted()
print("Unique group slots: \(uniqueSlots.count) (range \(uniqueSlots.first ?? -1)...\(uniqueSlots.last ?? -1))")

// ── C. Do 0x2425 entries map 1:1 to unique group slots? ──
print("\n══ C. 0x2425 ENTRY-TO-SLOT MAPPING ══")
// If 0x2425[i] corresponds to group slot i, check:
for i in 0..<min(b2425.count, 20) {
    let b = b2425[i]
    let slotName = slotNames[i] ?? "(no slot)"
    let empty = slotEmpty[i] ?? false
    let emptyTag = empty ? " [EMPTY]" : ""
    print("  0x2425[\(i)] → slot[\(i)] '\(slotName)'\(emptyTag)")
    print("    raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 40)))")
}

// ── D. Check if 0x2425 contains sentinel ordinals ──
print("\n══ D. SEARCH 0x2425 FOR SENTINEL ORDINALS ══")
// For each 0x2425 block, check if any u16 value matches a sentinel ordinal
// We know from PeepTestD: compounds 479,480 → sentinels 82,83 and compounds 79,80 → sentinels 84,85

// First, build compound→0x2523 counter map
let cmpdParents = blocks.filter{$0.contentType==0x262b}.sorted{$0.dataOffset<$1.dataOffset}
var compoundCounters: [Int: [Int]] = [:]
for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}
    compoundCounters[ci] = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
}

// For each 0x2425, scan for u16 values that look like sentinel ordinals
// Focus on blocks that correspond to non-empty group slots
var sentinelCandidates: [(slotIdx: Int, offset: Int, value: Int)] = []
for (i, b) in b2425.enumerated() {
    guard b.dataSize >= 4 else { continue }
    for off in stride(from: 0, to: b.dataSize - 1, by: 2) {
        let v = Int(u16(data, at: b.dataOffset + off))
        // Look for values in sentinel range (0-500)
        if v >= 0 && v <= 500 && v == i {  // Does any field equal the slot index?
            // Don't flag - too noisy
        }
    }
}

// More targeted: what's at consistent offsets across all 0x2425 blocks?
print("\nConsistent offset analysis (first 4 u16 values):")
for (i, b) in b2425.enumerated() {
    guard i < 10 || (i >= 78 && i <= 86) || (i >= 160 && i <= 170) else { continue }
    guard b.dataSize >= 8 else { continue }
    let v0 = Int(u16(data, at: b.dataOffset))
    let v1 = Int(u16(data, at: b.dataOffset + 2))
    let v2 = Int(u16(data, at: b.dataOffset + 4))
    let v3 = Int(u16(data, at: b.dataOffset + 6))
    let slotName = slotNames[i] ?? "?"
    let empty = (slotEmpty[i] ?? false) ? " [E]" : ""
    print("  [\(i)] u16: \(v0), \(v1), \(v2), \(v3)  '\(slotName)'\(empty)")
}

// ── E. Parent context: where do 0x2425 blocks live? ──
print("\n══ E. 0x2425 PARENT CONTEXT ══")
if let first = b2425.first {
    // Find containing blocks
    let parents = blocks.filter { $0.dataOffset < first.dataOffset - 9 &&
        $0.dataOffset + $0.dataSize >= first.dataOffset + first.dataSize }
        .sorted { $0.dataSize < $1.dataSize }
    print("Parents of first 0x2425:")
    for p in parents.prefix(5) {
        print("  type=0x\(String(format:"%04x",p.contentType)) offset=\(p.dataOffset) size=\(p.dataSize)")
    }

    // What other block types are siblings (in same parent)?
    if let innerParent = parents.first {
        let siblings = blocks.filter { $0.dataOffset >= innerParent.dataOffset &&
            $0.dataOffset + $0.dataSize <= innerParent.dataOffset + innerParent.dataSize &&
            $0.contentType != 0x2425 }
        var sibTypes: [UInt16: Int] = [:]
        for s in siblings { sibTypes[s.contentType, default: 0] += 1 }
        print("Sibling types in parent 0x\(String(format:"%04x",innerParent.contentType)):")
        for (ct, count) in sibTypes.sorted(by:{$0.key<$1.key}) {
            print("  0x\(String(format:"%04x",ct)): \(count)")
        }
    }
}

// ── F. Do 0x2425 blocks contain compound pool indices? ──
print("\n══ F. SEARCH 0x2425 FOR COMPOUND POOL INDICES ══")
// We know compound pool indices for groups: check if 0x2425[slot] contains the compound pool index
// Build: group slot → compound pool indices (compounds whose 0x2423 idx matches)
var slotToCompounds: [Int: [Int]] = [:]
for (entryIdx, entry) in groupEntries.enumerated() {
    // Find which compound this 0x2423 entry might correspond to
    // The 0x2423 idx is the group slot
    slotToCompounds[entry.idx, default: []].append(entryIdx)
}

// For the interesting compounds (79,80,479,480), which group slot are they in?
print("Compound→group slot mapping via 0x2423:")
// Each 0x2423 entry has an idx. Multiple entries can share same idx (edit history).
// The compound pool index (0x262b position) might appear in the 0x2423 data or 0x2425 data.

// Try: for each 0x2425 block, check all u16 and u32 values against known compound indices
let targetCompounds = [79, 80, 479, 480]
for (i, b) in b2425.enumerated() {
    var found: [(offset: Int, width: Int, value: Int)] = []
    for tc in targetCompounds {
        // Check u16
        for off in 0..<(b.dataSize - 1) {
            if Int(u16(data, at: b.dataOffset + off)) == tc {
                found.append((off, 2, tc))
            }
        }
        // Check u32
        for off in 0..<(b.dataSize - 3) {
            if Int(u32(data, at: b.dataOffset + off)) == tc {
                found.append((off, 4, tc))
            }
        }
    }
    if !found.isEmpty {
        print("  0x2425[\(i)] '\(slotNames[i] ?? "?")': \(found.map{"u\($0.width*8)@\($0.offset)=\($0.value)"}.joined(separator:", "))")
        print("    raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 60)))")
    }
}

// ── G. Sentinel count and range ──
print("\n══ G. SENTINEL INFO ══")
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
guard all1054.count >= 2 else { print("Not enough 0x1054"); exit(0) }
let sc = all1054[1]; let ss=sc.dataOffset,se=ss+sc.dataSize
let ir = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
let sentinelSections = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
    !ir.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.sorted{$0.dataOffset<$1.dataOffset}
print("Sentinel sections: \(sentinelSections.count)")
print("Non-empty group slots: \(uniqueSlots.count - (slotEmpty.values.filter{$0}.count))")
print("Empty group slots: \(slotEmpty.values.filter{$0}.count)")

// ── H. Key hypothesis: non-empty 0x2423 entries allocate sentinels sequentially ──
print("\n══ H. NON-EMPTY ENTRY → SENTINEL MAPPING ══")
// Theory: iterate 0x2423 entries in order. Each non-empty entry allocates the next sentinel ordinal.
// Empty entries are skipped (or consumed — test both).
var sentOrd = 0
print("Model A: skip empty entries (only non-empty get sentinels)")
for (i, e) in groupEntries.enumerated() {
    if e.isEmpty { continue }
    guard i < 20 || (sentOrd >= 78 && sentOrd <= 90) || i >= groupEntries.count - 5 else { sentOrd += 1; continue }
    print("  entry[\(i)] idx=\(e.idx) '\(e.name)' → sentinel[\(sentOrd)]")
    sentOrd += 1
}
print("  Total non-empty entries allocated: \(sentOrd) vs sentinel count: \(sentinelSections.count)")

sentOrd = 0
print("\nModel B: ALL entries (including empty) consume sentinel slots")
for (i, e) in groupEntries.enumerated() {
    guard i < 10 || (sentOrd >= 78 && sentOrd <= 90) || i >= groupEntries.count - 5 else { sentOrd += 1; continue }
    let tag = e.isEmpty ? " [EMPTY]" : ""
    print("  entry[\(i)] idx=\(e.idx) '\(e.name)'\(tag) → sentinel[\(sentOrd)]")
    sentOrd += 1
}
print("  Total entries: \(sentOrd) vs sentinel count: \(sentinelSections.count)")

// ── I. Model C: unique group slots allocate sentinels, not entries ──
print("\n══ I. MODEL C: UNIQUE SLOTS → SENTINELS ══")
// Each unique group slot idx (0-226) maps to a sentinel.
// If slot count (227) < sentinel count, maybe non-empty slots get sentinels.
let nonEmptySlots = uniqueSlots.filter { !(slotEmpty[$0] ?? false) }
let emptySlots = uniqueSlots.filter { slotEmpty[$0] ?? false }
print("Non-empty unique slots: \(nonEmptySlots.count)")
print("Empty unique slots: \(emptySlots.count)")
print("If non-empty slots = sentinels: \(nonEmptySlots.count) vs \(sentinelSections.count)")
print("If all slots = sentinels: \(uniqueSlots.count) vs \(sentinelSections.count)")

// ── J. Content matching: verify sentinel content against slot names ──
print("\n══ J. CONTENT MATCH: SLOT NAME vs SENTINEL CONTENT ══")
// For each sentinel, extract the audio clip names from its 0x104f children
// Then check if the slot at that ordinal has the right group name
let audioPool = blocks.filter{$0.contentType==0x2629}.sorted{$0.dataOffset<$1.dataOffset}
func audioName(_ idx: Int) -> String {
    guard idx < audioPool.count else { return "?" }
    let a = audioPool[idx]
    let ch = blocks.filter{$0.contentType==0x2628 && $0.dataOffset>=a.dataOffset && $0.dataOffset+$0.dataSize<=a.dataOffset+a.dataSize}
    guard let nb = ch.first else { return "?" }
    let nl = Int(u32(data, at: nb.dataOffset))
    guard nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count else { return "?" }
    return String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
}

func compoundName(_ idx: Int) -> String {
    guard idx < cmpdParents.count else { return "?" }
    let c = cmpdParents[idx]
    let ch = blocks.filter{$0.contentType==0x2628 && $0.dataOffset>=c.dataOffset && $0.dataOffset+$0.dataSize<=c.dataOffset+c.dataSize}
    guard let nb = ch.first else { return "?" }
    let nl = Int(u32(data, at: nb.dataOffset))
    guard nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count else { return "?" }
    return String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
}

// Show sentinel content for first 10 and near 82-85
for (si, sect) in sentinelSections.enumerated() {
    guard si < 10 || (si >= 80 && si <= 86) else { continue }
    let clips = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
        $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
    let clipNames = clips.compactMap { clip -> String? in
        let ci = Int(u16(data, at: clip.dataOffset + 2))
        let b18 = data[clip.dataOffset + 18]
        return b18 == 0x00 ? audioName(ci) : "compound[\(ci)]:\(compoundName(ci))"
    }
    let slotName = si < uniqueSlots.count ? (slotNames[si] ?? "?") : "?"
    print("  sentinel[\(si)] clips=\(clipNames.prefix(3)) | slot[\(si)]='\(slotName)'")
}

print("\nDone.")
