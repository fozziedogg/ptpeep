#!/usr/bin/env swift
// sentinel_diag13.swift — 2-byte UUID tail family matching for out-of-range compounds
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

func getName(_ idx: Int) -> String {
    guard idx < cmpdParents.count else { return "?" }
    let p = cmpdParents[idx]
    let ch = blocks.filter{$0.contentType==0x2628 && $0.dataOffset>=p.dataOffset && $0.dataOffset+$0.dataSize<=p.dataOffset+p.dataSize}
    guard let nb = ch.first else { return "?" }
    let nl = Int(u32(data, at: nb.dataOffset))
    guard nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count else { return "?" }
    return String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
}

// Sentinel count
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
guard all1054.count >= 2 else { exit(0) }
let sc = all1054[1]; let ss=sc.dataOffset, se=ss+sc.dataSize
let innerR = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
let sentCount = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
    !innerR.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.count
print("Sentinels: \(sentCount)")

// Build compound → counter and UUID bytes[23-24] (2-byte tail)
struct CompInfo {
    let ci: Int
    let counters: [Int]
    let uuid4: Data   // bytes[21-24]
    let tail2: UInt16  // bytes[23-24] as u16
}

var allCompInfo: [CompInfo] = []
var tailFamilies: [UInt16: [Int]] = [:]  // tail → [ci]

for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}.sorted{$0.dataOffset<$1.dataOffset}
    guard let first = c2523s.first else { continue }
    let counters = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
    let uuid4 = Data(data[first.dataOffset+21..<first.dataOffset+25])
    let tail2 = u16(data, at: first.dataOffset + 23)
    let info = CompInfo(ci: ci, counters: counters, uuid4: uuid4, tail2: tail2)
    allCompInfo.append(info)
    tailFamilies[tail2, default: []].append(ci)
}

// 0x2425 counter → slot
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

// Out-of-range targets
let targets = [479, 480, 457, 458, 498, 441, 331, 547]

print("\n══ 2-BYTE TAIL FAMILY MATCHING ══")
for ci in targets {
    guard let info = allCompInfo.first(where: { $0.ci == ci }) else { continue }
    let family = tailFamilies[info.tail2] ?? []
    let familyInfo = family.compactMap { fci -> (Int, String, [Int], [Int])? in
        guard let fi = allCompInfo.first(where: { $0.ci == fci }) else { return nil }
        let inRange = fi.counters.filter { $0 < sentCount }
        return (fci, getName(fci), fi.counters, inRange)
    }.sorted { ($0.2.first ?? 0) < ($1.2.first ?? 0) }

    let allInRange = familyInfo.flatMap { $0.3 }

    print("\n━━ compound[\(ci)] '\(getName(ci))' counter=\(info.counters) tail=\(String(format:"%04x", info.tail2)) ━━")
    print("  Family size: \(family.count)")

    // Only show family members with in-range counters (plus the target itself)
    for fi in familyInfo where !fi.3.isEmpty || fi.0 == ci {
        let marker = fi.0 == ci ? " ← THIS" : ""
        let slots = Set(fi.3.compactMap { counterToSlot[$0] })
        print("    compound[\(fi.0)] '\(fi.1)' counters=\(fi.2) inRange=\(fi.3) slots=\(slots.sorted())\(marker)")
    }

    if allInRange.isEmpty {
        print("  ⚠ NO family member has in-range counter!")
    } else {
        let slots = Set(allInRange.compactMap { counterToSlot[$0] }).sorted()
        print("  In-range sentinels: \(allInRange.sorted())")
        print("  Slots: \(slots) → \(slots.map { "'\(slotNames[$0] ?? "?")'" }.joined(separator: ", "))")

        // Show LAST sentinel per slot (most recent version)
        for slot in slots {
            let sentinels = slotSentinels[slot]
            print("  slot[\(slot)] sentinels=\(sentinels) last=\(sentinels.last ?? -1)")
        }
    }
}

// ── Alternative: check if clipIdx itself works as sentinel ordinal ──
print("\n\n══ ALTERNATIVE: CLIP POOL INDEX AS SENTINEL ORDINAL ══")
for ci in targets {
    let valid = ci < sentCount ? "✓ (in range)" : "✗ (out of range)"
    print("  compound[\(ci)] '\(getName(ci))' → sentinel[\(ci)] \(valid)")
}

// ── Check the 0x2526 blocks (actual UUID blocks, not 0x2523 bytes) ──
print("\n\n══ ACTUAL 0x2526 BLOCK CONTENTS ══")
for ci in targets {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let uuids = blocks.filter { $0.contentType == 0x2526 && $0.dataOffset >= cmpd.dataOffset &&
        $0.dataOffset + $0.dataSize <= cmpd.dataOffset + cmpd.dataSize }
    for u in uuids {
        print("  compound[\(ci)] '\(getName(ci))' 0x2526 (\(u.dataSize)b): \(hexDump(data, at: u.dataOffset, count: u.dataSize))")
    }
}

// Show 0x2526 for in-range family members for comparison
print("\n0x2526 for in-range family members:")
for ci in [79, 80, 81, 68, 155, 180, 233, 234, 253] {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let uuids = blocks.filter { $0.contentType == 0x2526 && $0.dataOffset >= cmpd.dataOffset &&
        $0.dataOffset + $0.dataSize <= cmpd.dataOffset + cmpd.dataSize }
    for u in uuids {
        let counters = allCompInfo.first(where: { $0.ci == ci })?.counters ?? []
        print("  compound[\(ci)] '\(getName(ci))' counter=\(counters) 0x2526 (\(u.dataSize)b): \(hexDump(data, at: u.dataOffset, count: u.dataSize))")
    }
}

print("\nDone.")
