#!/usr/bin/env swift
// sentinel_diag3.swift — Check if 0x2526 UUID links split compounds to parents
// and verify which sentinels are owned by which counter ranges
import Foundation

struct Block { let contentType: UInt16; let dataOffset: Int; let dataSize: Int }
func u16(_ d: Data, at i: Int) -> UInt16 { guard i+2<=d.count else{return 0}; return UInt16(d[i])|(UInt16(d[i+1])<<8) }
func u32(_ d: Data, at i: Int) -> UInt32 { guard i+4<=d.count else{return 0}; return UInt32(d[i])|(UInt32(d[i+1])<<8)|(UInt32(d[i+2])<<16)|(UInt32(d[i+3])<<24) }
func readLE(_ d: Data, at i: Int, count: Int) -> UInt64 { var v:UInt64=0; for k in 0..<count where i+k<d.count{v|=UInt64(d[i+k])<<(k*8)}; return v }
func hexDump(_ d: Data, at o: Int, count c: Int) -> String { let e=min(o+c,d.count); guard o<e else{return""}; return (o..<e).map{String(format:"%02x",d[$0])}.joined(separator:" ") }

func xorDecode(_ raw: Data) -> Data? {
    guard raw.count>0x14 else{return nil}
    let ft=raw[0x12],xv=raw[0x13]; let mul:UInt16,neg:Bool
    switch ft{case 0x05:mul=11;neg=true;case 0x01:mul=53;neg=false;default:return nil}
    var delta:UInt8=0
    for i:UInt16 in 0...255{if(i*mul)&0xff==UInt16(xv){delta=neg ? UInt8(truncatingIfNeeded:256 &- Int(i)):UInt8(i);break}}
    var tab=[UInt8](repeating:0,count:256); for i in 0..<256{tab[i]=UInt8((UInt16(i)*UInt16(delta))&0xff)}
    var dec=raw
    if ft==0x05{for ch in stride(from:4096,to:raw.count,by:4096){let x=tab[(ch>>12)&0xff];guard x != 0 else{continue};let e=min(ch+4096,raw.count);for i in ch..<e{dec[i]=raw[i]^x}}}
    else{for i in 0..<raw.count{dec[i]=raw[i]^tab[i&0xff]}}
    return dec
}
func scanBlocks(_ d: Data) -> [Block] {
    var b=[Block]();var i=0x1f
    while i+9<=d.count{guard d[i]==0x5a else{i+=1;continue};let s=Int(u32(d,at:i+3)),c=u16(d,at:i+7)
    guard s>0,s<50_000_000,i+9+s<=d.count else{i+=1;continue};b.append(Block(contentType:c,dataOffset:i+9,dataSize:s));i+=1};return b
}
func children(of p: Block, in bs: [Block]) -> [Block] {
    let e=p.dataOffset+p.dataSize
    return bs.filter{$0.dataOffset>=p.dataOffset && $0.dataOffset+$0.dataSize<=e && $0.dataOffset != p.dataOffset}
}

guard CommandLine.arguments.count>1 else{print("Usage: ...");exit(1)}
guard let raw=try? Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])) else{print("err");exit(1)}
guard let data=xorDecode(raw) else{print("xor err");exit(1)}
let blocks=scanBlocks(data)
let cmpdParents=blocks.filter{$0.contentType==0x262b}.sorted{$0.dataOffset<$1.dataOffset}
let audioParents=blocks.filter{$0.contentType==0x2629}.sorted{$0.dataOffset<$1.dataOffset}

// Get name for compound
func cname(_ ci: Int) -> String {
    guard ci<cmpdParents.count else{return"?"}
    let ch=children(of:cmpdParents[ci],in:blocks)
    if let nb=ch.first(where:{$0.contentType==0x2628}){
        let nl=Int(u32(data,at:nb.dataOffset))
        if nl>0,nl<512,nb.dataOffset+4+nl<=data.count{return String(bytes:data[nb.dataOffset+4..<nb.dataOffset+4+nl],encoding:.utf8) ?? "?"}
    }
    return "?"
}

// ── A. 0x2526 UUID grouping ──
print("══ A. 0x2526 UUID → compound grouping ══")
print("Showing last 2 bytes of 0x2526 (UUID prefix) for compounds that share UUIDs")

// Map: uuid_tail_2bytes → [compound indices]
var uuidMap: [String: [Int]] = [:]
for (ci, cmpd) in cmpdParents.enumerated() {
    let ch = children(of: cmpd, in: blocks)
    let c2526s = ch.filter { $0.contentType == 0x2526 }
    for r in c2526s {
        if r.dataSize >= 14 {
            let tail = hexDump(data, at: r.dataOffset + 12, count: 2)
            uuidMap[tail, default: []].append(ci)
        }
    }
}

// Find groups that contain our known split compounds (79, 80, 479, 480)
let splitCIs: Set<Int> = [79, 80, 479, 480]
for (uuid, cis) in uuidMap.sorted(by: { $0.value.count > $1.value.count }) {
    if cis.contains(where: { splitCIs.contains($0) }) || cis.count > 10 {
        let names = cis.prefix(20).map { "[\($0)] \(cname($0))" }
        print("  UUID tail '\(uuid)': \(cis.count) compounds")
        for n in names { print("    \(n)") }
        if cis.count > 20 { print("    ... and \(cis.count - 20) more") }
    }
}

// ── B. Counter ranges → sentinel ownership ──
print("\n══ B. COUNTER RANGES (which compound owns which sentinels?) ══")

struct CounterRange {
    let ci: Int
    let first: Int
    let last: Int
    let count: Int
}
var ranges: [CounterRange] = []
for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = children(of: cmpd, in: blocks).filter { $0.contentType == 0x2523 }
    let counters = c2523s.compactMap { m -> Int? in
        guard m.dataSize >= 39 else { return nil }
        return Int(readLE(data, at: m.dataOffset + 37, count: 2))
    }
    guard let first = counters.min(), let last = counters.max() else { continue }
    ranges.append(CounterRange(ci: ci, first: first, last: last, count: counters.count))
}
ranges.sort { $0.first < $1.first }

// Print ranges that include sentinels 82-85
print("\nCounter ranges that include sentinels 82-85:")
for r in ranges where r.first <= 85 && r.last >= 82 {
    print("  compound[\(r.ci)] '\(cname(r.ci))' counters [\(r.first)..\(r.last)] (\(r.count) events)")
}

// Print ranges for our target compounds
print("\nCounter ranges for target compounds:")
for ci in [41, 79, 80, 479, 480] {
    if let r = ranges.first(where: { $0.ci == ci }) {
        print("  compound[\(ci)] '\(cname(ci))' counters [\(r.first)..\(r.last)] (\(r.count) events)")
    }
}

// ── C. Sentinel content at counter values for compound[79] and compound[41] ──
print("\n══ C. SENTINEL CONTENT AT VARIOUS ORDINALS ══")

let all1054=blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
var sentinelSections: [Block] = []
if all1054.count>=2{
    let sc=all1054[1]; let ss=sc.dataOffset,se=ss+sc.dataSize
    let ir=blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
    sentinelSections=blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se && !ir.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.sorted{$0.dataOffset<$1.dataOffset}
}
let SENT_ORIGIN:UInt64=1_000_000_000_000

func sentinelInfo(_ idx: Int) -> String {
    guard idx < sentinelSections.count else { return "OUT OF RANGE" }
    let sect = sentinelSections[idx]
    let pls = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset && $0.dataOffset+$0.dataSize <= sect.dataOffset+sect.dataSize }
    var cis: [Int] = []
    for pl in pls {
        guard pl.dataSize >= 19 else { continue }
        let tl = readLE(data, at: pl.dataOffset+7, count: 8)
        guard tl >= SENT_ORIGIN else { continue }
        cis.append(Int(u16(data, at: pl.dataOffset+2)))
    }
    // Get audio names for first 3 ci values
    var names: [String] = []
    for ci in cis.prefix(3) {
        guard ci < audioParents.count else { names.append("ci=\(ci)?"); continue }
        let ap = audioParents[ci]
        let ch = children(of: ap, in: blocks)
        if let nb = ch.first(where: { $0.contentType == 0x2628 }) {
            let nl = Int(u32(data, at: nb.dataOffset))
            if nl > 0, nl < 512, nb.dataOffset+4+nl<=data.count {
                let n = String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
                names.append(n)
            }
        }
    }
    let extra = cis.count > 3 ? " +\(cis.count-3) more" : ""
    return "\(cis.count) clips: \(names.joined(separator: ", "))\(extra)"
}

// Check sentinels for split compounds
print("Sentinel ordinals relevant to the split compounds:")
for idx in [82, 83, 84, 85, 179, 180, 747, 748] {
    print("  sentinel[\(idx)]: \(sentinelInfo(idx))")
}

// Also check sentinel[65] (first counter of compound[41]) and sentinel[128] (last)
print("\nSentinel ordinals for compound[41] 'dx 1.grp-23' range:")
for idx in [65, 82, 83, 84, 85, 128] {
    print("  sentinel[\(idx)]: \(sentinelInfo(idx))")
}

// ── D. Full UUID dump for split family ──
print("\n══ D. FULL 0x2526 CONTENT for split family ══")

// Dump compound[41] (suspected parent) and split compounds
for ci in [41, 79, 80, 479, 480] {
    guard ci < cmpdParents.count else { continue }
    let ch = children(of: cmpdParents[ci], in: blocks)
    let c2526s = ch.filter { $0.contentType == 0x2526 }.sorted { $0.dataOffset < $1.dataOffset }
    let c2523s = ch.filter { $0.contentType == 0x2523 }.sorted { $0.dataOffset < $1.dataOffset }
    print("  compound[\(ci)] '\(cname(ci))':")
    for (j, r) in c2526s.enumerated() {
        print("    0x2526[\(j)]: \(hexDump(data, at: r.dataOffset, count: r.dataSize))")
    }
    // Also show bytes[21..24] of 0x2523 (the UUID-like bytes)
    for (j, m) in c2523s.enumerated() {
        if m.dataSize > 24 {
            print("    0x2523[\(j)] bytes[21..24]: \(hexDump(data, at: m.dataOffset+21, count: 4))")
        }
    }
}

// ── E. Total 0x2523 count and sentinel count comparison ──
print("\n══ E. COUNTER ALLOCATION SUMMARY ══")
var totalCounters = 0
var maxCounter = 0
for (_, cmpd) in cmpdParents.enumerated() {
    let c2523s = children(of: cmpd, in: blocks).filter { $0.contentType == 0x2523 }
    totalCounters += c2523s.count
    for m in c2523s where m.dataSize >= 39 {
        let c = Int(readLE(data, at: m.dataOffset + 37, count: 2))
        if c > maxCounter { maxCounter = c }
    }
}
print("Total 0x2523 blocks: \(totalCounters)")
print("Max counter value: \(maxCounter)")
print("Sentinel sections: \(sentinelSections.count)")
print("Difference (max counter - sentinel count + 1): \(maxCounter - sentinelSections.count + 1)")

// Are counters contiguous?
var allCounters: [Int] = []
for (_, cmpd) in cmpdParents.enumerated() {
    let c2523s = children(of: cmpd, in: blocks).filter { $0.contentType == 0x2523 }
    for m in c2523s where m.dataSize >= 39 {
        allCounters.append(Int(readLE(data, at: m.dataOffset + 37, count: 2)))
    }
}
allCounters.sort()
var gaps: [(Int, Int)] = []
for i in 1..<allCounters.count {
    if allCounters[i] != allCounters[i-1] + 1 {
        gaps.append((allCounters[i-1], allCounters[i]))
    }
}
print("Counter gaps: \(gaps.isEmpty ? "none (contiguous 0..\(maxCounter))" : "\(gaps)")")

print("\nDone.")
