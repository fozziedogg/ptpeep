#!/usr/bin/env swift
// sentinel_diag8.swift — Verify 0x2425 → sentinel ordinal mapping
// Hypothesis: 0x2425[i] contains the list of sentinel ordinals belonging to group slot i
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

guard CommandLine.arguments.count>1 else{print("Usage: sentinel_diag8.swift <file.ptx>");exit(1)}
guard let raw=try? Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])) else{print("err");exit(1)}
guard let data=xorDecode(raw) else{print("xor err");exit(1)}
let blocks=scanBlocks(data)

// ── Parse 0x2425 blocks: structure is [count:u32] [count × (00 + index:u32)] [file path...] ──
let b2425 = blocks.filter{$0.contentType==0x2425}.sorted{$0.dataOffset<$1.dataOffset}
print("0x2425 blocks: \(b2425.count)")

struct SlotInfo {
    let slotIdx: Int
    let indices: [Int]  // sentinel ordinals?
}

var slots: [SlotInfo] = []
var allIndices: [Int] = []  // flattened
var indexToSlot: [Int: Int] = [:]  // index → slot idx

for (si, b) in b2425.enumerated() {
    guard b.dataSize >= 4 else { continue }
    let count = Int(u32(data, at: b.dataOffset))
    var indices: [Int] = []
    var offset = 4
    for _ in 0..<count {
        guard offset + 5 <= b.dataSize else { break }
        // skip 0x00 byte
        offset += 1
        let idx = Int(u32(data, at: b.dataOffset + offset))
        indices.append(idx)
        offset += 4
    }
    slots.append(SlotInfo(slotIdx: si, indices: indices))
    for idx in indices {
        allIndices.append(idx)
        indexToSlot[idx] = si
    }
}

print("Total indices across all slots: \(allIndices.count)")
print("Unique indices: \(Set(allIndices).count)")
print("Index range: \(allIndices.min() ?? -1) ... \(allIndices.max() ?? -1)")

// ── Parse 0x2423 for group slot names ──
let b2423 = blocks.filter{$0.contentType==0x2423}.sorted{$0.dataOffset<$1.dataOffset}
var slotNames: [Int: String] = [:]
var slotEmpty: [Int: Bool] = [:]
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
    slotNames[idx] = name
    slotEmpty[idx] = isEmpty
}

// ── Sentinel count ──
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
guard all1054.count >= 2 else { print("Not enough 0x1054"); exit(0) }
let sc = all1054[1]; let ss=sc.dataOffset,se=ss+sc.dataSize
let ir = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
let sentinelSections = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
    !ir.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.sorted{$0.dataOffset<$1.dataOffset}
print("\nSentinel sections: \(sentinelSections.count)")
print("Match? indices=\(allIndices.count) vs sentinels=\(sentinelSections.count)")

// ── Check which slot owns sentinels 82, 83, 84, 85 ──
print("\n══ WHICH SLOT OWNS TARGET SENTINELS? ══")
for target in [82, 83, 84, 85] {
    if let si = indexToSlot[target] {
        let name = slotNames[si] ?? "?"
        let empty = (slotEmpty[si] ?? false) ? " [EMPTY]" : ""
        let indices = slots[si].indices
        print("  sentinel \(target) → slot[\(si)] '\(name)'\(empty) (owns indices: \(indices))")
    } else {
        print("  sentinel \(target) → NOT FOUND in any slot!")
    }
}

// ── Verify: content match sentinel[ordinal] against compound names ──
print("\n══ CONTENT VERIFICATION ══")
let cmpdParents = blocks.filter{$0.contentType==0x262b}.sorted{$0.dataOffset<$1.dataOffset}
let audioPool = blocks.filter{$0.contentType==0x2629}.sorted{$0.dataOffset<$1.dataOffset}

func getName(_ pool: [Block], _ idx: Int) -> String {
    guard idx < pool.count else { return "?" }
    let p = pool[idx]
    let ch = blocks.filter{$0.contentType==0x2628 && $0.dataOffset>=p.dataOffset && $0.dataOffset+$0.dataSize<=p.dataOffset+p.dataSize}
    guard let nb = ch.first else { return "?" }
    let nl = Int(u32(data, at: nb.dataOffset))
    guard nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count else { return "?" }
    return String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
}

// For sentinels 82-85, show their constituent clip names
for si in [82, 83, 84, 85] {
    guard si < sentinelSections.count else { continue }
    let sect = sentinelSections[si]
    let clips = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
        $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
    let clipDescs = clips.map { clip -> String in
        let ci = Int(u16(data, at: clip.dataOffset + 2))
        let b18 = data[clip.dataOffset + 18]
        return b18 == 0x00 ? "audio[\(ci)]:\(getName(audioPool, ci))" : "cmpd[\(ci)]:\(getName(cmpdParents, ci))"
    }
    let ownerSlot = indexToSlot[si]
    let ownerName = ownerSlot != nil ? slotNames[ownerSlot!] ?? "?" : "NONE"
    print("  sentinel[\(si)] owner=slot[\(ownerSlot ?? -1)] '\(ownerName)' clips=\(clipDescs.prefix(5))")
}

// ── Show compounds 79, 80, 479, 480 and their 0x2523 counters ──
print("\n══ TARGET COMPOUND INFO ══")
for ci in [79, 80, 479, 480] {
    let name = getName(cmpdParents, ci)
    // Get 0x2523 children
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}
    let counters = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
    print("  compound[\(ci)] '\(name)' counters=\(counters)")

    // Check: is the counter value one of sentinel indices in the slot?
    for counter in counters {
        if let si = indexToSlot[counter] {
            print("    counter \(counter) → slot[\(si)] '\(slotNames[si] ?? "?")'")
        }
    }
}

// ── Show what compound pool index maps to each 0x2423 entry ──
// 0x2423 entries have idx (group slot). Each compound has 0x2523 children with counters.
// Build: counter → compound pool index
print("\n══ COUNTER → COMPOUND MAPPING ══")
var counterToCompound: [Int: Int] = [:]
for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}
    for c in c2523s {
        let counter = Int(readLE(data, at: c.dataOffset + 37, count: 2))
        counterToCompound[counter] = ci
    }
}

// For each slot that owns sentinels 82-85, show the full mapping chain
print("\nFull mapping chain for sentinels 78-90:")
for sentIdx in 78...min(90, sentinelSections.count-1) {
    let ownerSlot = indexToSlot[sentIdx]
    let slotName = ownerSlot != nil ? slotNames[ownerSlot!] ?? "?" : "NONE"
    // Is this sentinel index also a counter?
    let compoundIdx = counterToCompound[sentIdx]
    let compoundName = compoundIdx != nil ? getName(cmpdParents, compoundIdx!) : "NONE"
    print("  sentinel[\(sentIdx)] → slot[\(ownerSlot ?? -1)] '\(slotName)' | counter→compound[\(compoundIdx ?? -1)] '\(compoundName)'")
}

// ── Key question: do the 0x2425 indices equal 0x2523 counters? ──
print("\n══ VERIFICATION: Are 0x2425 indices = 0x2523 creation counters? ══")
// If slot[i] owns indices [a,b,c], do those indices appear as counters in compounds
// that belong to group slot i?
var matchCount = 0
var mismatchCount = 0
for slot in slots {
    for idx in slot.indices {
        if let ci = counterToCompound[idx] {
            matchCount += 1
        } else {
            mismatchCount += 1
        }
    }
}
print("Indices that are valid counters: \(matchCount)")
print("Indices with no matching counter: \(mismatchCount)")

// ── Check: for a compound placed on the timeline, which sentinel does it use? ──
print("\n══ ACTIVE TIMELINE: COMPOUND → SENTINEL RESOLUTION ══")
let activeContainer = all1054[0]
let acStart = activeContainer.dataOffset, acEnd = acStart + activeContainer.dataSize
let activeSections = blocks.filter { b in
    b.contentType == 0x1052 && b.dataOffset >= acStart && b.dataOffset + b.dataSize <= acEnd
}.sorted { $0.dataOffset < $1.dataOffset }

// Find active placements with b18=0x01 (compound groups)
var compoundPlacements: [(sectionIdx: Int, clipIdx: Int)] = []
for (secIdx, sect) in activeSections.enumerated() {
    let refs = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
        $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
    for ref in refs {
        let b18 = data[ref.dataOffset + 18]
        if b18 == 0x01 {
            let ci = Int(u16(data, at: ref.dataOffset + 2))
            compoundPlacements.append((secIdx, ci))
        }
    }
}

print("Active compound placements: \(compoundPlacements.count)")

// For each compound, which 0x2523 counter does it use, and which slot owns that counter?
for (i, p) in compoundPlacements.enumerated() {
    guard i < 20 || [79, 80, 479, 480].contains(p.clipIdx) else { continue }
    let name = getName(cmpdParents, p.clipIdx)
    guard p.clipIdx < cmpdParents.count else { continue }
    let cmpd = cmpdParents[p.clipIdx]
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}
    let counters = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()

    // For single-counter compounds, the counter IS the sentinel ordinal
    // For multi-counter compounds, which counter is the right one?
    if counters.count == 1 {
        let sentOrd = counters[0]
        let ownerSlot = indexToSlot[sentOrd]
        print("  [\(i)] section[\(p.sectionIdx)] compound[\(p.clipIdx)] '\(name)' → counter=\(sentOrd) slot=\(ownerSlot ?? -1)")
    } else {
        // Multiple counters — need to pick the right one
        // Hypothesis: the LOWEST counter in the compound is the sentinel ordinal
        let minCounter = counters.first ?? -1
        let maxCounter = counters.last ?? -1
        let ownerSlotMin = indexToSlot[minCounter]
        let ownerSlotMax = indexToSlot[maxCounter]
        print("  [\(i)] section[\(p.sectionIdx)] compound[\(p.clipIdx)] '\(name)' → counters=\(counters.first!)...\(counters.last!) (\(counters.count)) minSlot=\(ownerSlotMin ?? -1) maxSlot=\(ownerSlotMax ?? -1)")
    }
}

print("\nDone.")
