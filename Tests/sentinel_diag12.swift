#!/usr/bin/env swift
// sentinel_diag12.swift — For out-of-range compounds, trace UUID family → in-range sentinels
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

guard CommandLine.arguments.count>1 else{print("Usage: ...");exit(1)}
guard let raw=try? Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])) else{print("err");exit(1)}
guard let data=xorDecode(raw) else{print("xor err");exit(1)}
let blocks=scanBlocks(data)

let cmpdParents = blocks.filter{$0.contentType==0x262b}.sorted{$0.dataOffset<$1.dataOffset}
let audioPool = blocks.filter{$0.contentType==0x2629}.sorted{$0.dataOffset<$1.dataOffset}

func getCompoundName(_ idx: Int) -> String {
    guard idx < cmpdParents.count else { return "?" }
    let p = cmpdParents[idx]
    let ch = blocks.filter{$0.contentType==0x2628 && $0.dataOffset>=p.dataOffset && $0.dataOffset+$0.dataSize<=p.dataOffset+p.dataSize}
    guard let nb = ch.first else { return "?" }
    let nl = Int(u32(data, at: nb.dataOffset))
    guard nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count else { return "?" }
    return String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
}
func getAudioName(_ idx: Int) -> String {
    guard idx < audioPool.count else { return "?" }
    let p = audioPool[idx]
    let ch = blocks.filter{$0.contentType==0x2628 && $0.dataOffset>=p.dataOffset && $0.dataOffset+$0.dataSize<=p.dataOffset+p.dataSize}
    guard let nb = ch.first else { return "?" }
    let nl = Int(u32(data, at: nb.dataOffset))
    guard nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count else { return "?" }
    return String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
}

// Build sentinel sections
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
guard all1054.count >= 2 else { print("Not enough 0x1054"); exit(0) }
let sc = all1054[1]; let ss=sc.dataOffset, se=ss+sc.dataSize
let ir = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
let sentinelSections = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
    !ir.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.sorted{$0.dataOffset<$1.dataOffset}
let sentCount = sentinelSections.count
print("Sentinels: \(sentCount)")

// Build counter → sentinel ordinal (0x2425)
let b2425 = blocks.filter{$0.contentType==0x2425}.sorted{$0.dataOffset<$1.dataOffset}
var counterToSlot: [Int: Int] = [:]
var slotSentinels: [[Int]] = []
for (si, b) in b2425.enumerated() {
    guard b.dataSize >= 4 else { slotSentinels.append([]); continue }
    let count = Int(u32(data, at: b.dataOffset))
    var indices: [Int] = []
    var offset = 4
    for _ in 0..<count {
        guard offset + 5 <= b.dataSize else { break }
        offset += 1; indices.append(Int(u32(data, at: b.dataOffset + offset))); offset += 4
    }
    slotSentinels.append(indices)
    for idx in indices { counterToSlot[idx] = si }
}

// Build compound → counters and UUID
var compoundCounterMap: [Int: [Int]] = [:]
var compoundUUID: [Int: Data] = [:]
for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}
    if !c2523s.isEmpty {
        compoundCounterMap[ci] = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
        // UUID from first 0x2523 bytes[21-24]
        compoundUUID[ci] = Data(data[c2523s[0].dataOffset+21..<c2523s[0].dataOffset+25])
    }
}

// Group by UUID
var uuidFamilies: [Data: [Int]] = [:]
for (ci, uuid) in compoundUUID {
    uuidFamilies[uuid, default: []].append(ci)
}

// Slot names
let b2423 = blocks.filter{$0.contentType==0x2423}.sorted{$0.dataOffset<$1.dataOffset}
var slotNames: [Int: String] = [:]
for b in b2423 {
    guard b.dataSize >= 8 else { continue }
    let idx = Int(u32(data, at: b.dataOffset))
    let nl = Int(u32(data, at: b.dataOffset + 4))
    if nl > 0, nl < 512, b.dataOffset + 8 + nl <= data.count {
        slotNames[idx] = String(bytes: data[b.dataOffset+8..<b.dataOffset+8+nl], encoding: .utf8) ?? "?"
    }
}

// Find active compounds with out-of-range counters
let activeContainer = all1054[0]
let activeSections = blocks.filter { b in
    b.contentType == 0x1052 && b.dataOffset >= activeContainer.dataOffset &&
    b.dataOffset + b.dataSize <= activeContainer.dataOffset + activeContainer.dataSize
}.sorted { $0.dataOffset < $1.dataOffset }

var outOfRangeCompounds: [Int] = []
for sect in activeSections {
    let refs = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
        $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
    for ref in refs where data[ref.dataOffset + 18] == 0x01 {
        let ci = Int(u16(data, at: ref.dataOffset + 2))
        let counters = compoundCounterMap[ci] ?? []
        if let first = counters.first, first >= sentCount {
            outOfRangeCompounds.append(ci)
        }
    }
}

print("Out-of-range compounds on timeline: \(outOfRangeCompounds)")

func sentinelContent(_ si: Int) -> [(ci: Int, isCompound: Bool, name: String)] {
    guard si >= 0, si < sentinelSections.count else { return [] }
    let sect = sentinelSections[si]
    let clips = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
        $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
    return clips.map { clip in
        let ci = Int(u16(data, at: clip.dataOffset + 2))
        let b18 = data[clip.dataOffset + 18]
        let name = b18 == 0x00 ? getAudioName(ci) : getCompoundName(ci)
        return (ci, b18 == 0x01, name)
    }
}

print("\n══ UUID FAMILY ANALYSIS FOR OUT-OF-RANGE COMPOUNDS ══")
for ci in outOfRangeCompounds {
    guard let uuid = compoundUUID[ci] else { continue }
    let family = uuidFamilies[uuid] ?? []
    let name = getCompoundName(ci)
    let counters = compoundCounterMap[ci] ?? []

    print("\n━━ compound[\(ci)] '\(name)' counter=\(counters) UUID=\(hexDump(uuid, at: 0, count: uuid.count)) ━━")

    // Sort family by counter
    let familyInfo = family.map { fc -> (ci: Int, name: String, counters: [Int], inRange: [Int]) in
        let fc_counters = compoundCounterMap[fc] ?? []
        let inRange = fc_counters.filter { $0 < sentCount }
        return (fc, getCompoundName(fc), fc_counters, inRange)
    }.sorted { ($0.counters.first ?? 0) < ($1.counters.first ?? 0) }

    print("  Family (\(family.count) members):")
    for fi in familyInfo {
        let slots = Set(fi.inRange.compactMap { counterToSlot[$0] })
        let marker = fi.ci == ci ? " ← THIS" : ""
        print("    compound[\(fi.ci)] '\(fi.name)' counters=\(fi.counters) inRange=\(fi.inRange) slots=\(slots.sorted())\(marker)")
    }

    // Show sentinel content for all in-range family members
    let allInRange = familyInfo.flatMap { $0.inRange }.sorted()
    let allSlots = Set(allInRange.compactMap { counterToSlot[$0] }).sorted()
    print("  All in-range sentinels: \(allInRange)")
    print("  All slots: \(allSlots) (\(allSlots.map { slotNames[$0] ?? "?" }))")

    for si in allInRange {
        let content = sentinelContent(si)
        let slot = counterToSlot[si]
        print("  sentinel[\(si)] (slot \(slot ?? -1)):")
        for c in content.prefix(10) {
            let typeTag = c.isCompound ? "CMPD" : "AUD"
            print("    [\(typeTag)] ci=\(c.ci) '\(c.name)'")
        }
        if content.count > 10 { print("    ... +\(content.count - 10) more") }
    }
}

// ── Also: check block types INSIDE compound pool entries we haven't examined ──
print("\n\n══ UNEXPLORED BLOCK TYPES IN COMPOUND POOL ENTRIES ══")
var compoundChildTypes: [UInt16: Int] = [:]
for ci in outOfRangeCompounds {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let children = blocks.filter { $0.dataOffset >= cmpd.dataOffset && $0.dataOffset + $0.dataSize <= cmpd.dataOffset + cmpd.dataSize }
    for ch in children {
        compoundChildTypes[ch.contentType, default: 0] += 1
    }
}
print("Block types inside out-of-range compound pool entries:")
for (ct, count) in compoundChildTypes.sorted(by: { $0.key < $1.key }) {
    print("  0x\(String(format: "%04x", ct)): \(count)")
}

// Dump any NON-standard children (not 0x2523, 0x2526, 0x2628, 0x2629, 0x262b)
let knownTypes: Set<UInt16> = [0x2523, 0x2526, 0x2628, 0x262b]
for ci in outOfRangeCompounds.prefix(3) {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let children = blocks.filter { $0.dataOffset >= cmpd.dataOffset && $0.dataOffset + $0.dataSize <= cmpd.dataOffset + cmpd.dataSize && !knownTypes.contains($0.contentType) }
    if !children.isEmpty {
        print("\ncompound[\(ci)] '\(getCompoundName(ci))' non-standard children:")
        for ch in children {
            print("  0x\(String(format: "%04x", ch.contentType)) size=\(ch.dataSize) raw: \(hexDump(data, at: ch.dataOffset, count: min(ch.dataSize, 40)))")
        }
    }
}

print("\nDone.")
