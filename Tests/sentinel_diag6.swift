#!/usr/bin/env swift
// sentinel_diag6.swift — Full 0x2423 dump + empty group counting
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

let b2423 = blocks.filter{$0.contentType==0x2423}.sorted{$0.dataOffset<$1.dataOffset}
print("0x2423 entries: \(b2423.count)")

struct GroupEvent {
    let entryIdx: Int    // position in 0x2423 list
    let groupIdx: Int    // the idx field
    let name: String
    let isEmpty: Bool    // ff trailing = empty group
    let trail: String
}

var events: [GroupEvent] = []
for (i, b) in b2423.enumerated() {
    guard b.dataSize >= 8 else { continue }
    let idx = Int(u32(data, at: b.dataOffset))
    let nl = Int(u32(data, at: b.dataOffset + 4))
    var name = "?"
    if nl > 0, nl < 512, b.dataOffset + 8 + nl <= data.count {
        name = String(bytes: data[b.dataOffset+8..<b.dataOffset+8+nl], encoding: .utf8) ?? "?"
    }
    let trailStart = b.dataOffset + 8 + nl
    let trailLen = b.dataSize - 8 - nl
    let trail = trailLen > 0 ? hexDump(data, at: trailStart, count: min(trailLen, 5)) : ""
    let isEmpty = trailLen >= 1 && data[trailStart] == 0xff
    events.append(GroupEvent(entryIdx: i, groupIdx: idx, name: name, isEmpty: isEmpty, trail: trail))
}

// Print all events with empty marking
print("\nAll 0x2423 events:")
var emptyCount = 0
for e in events {
    let tag = e.isEmpty ? " [EMPTY]" : ""
    if e.isEmpty { emptyCount += 1 }
    print("  [\(e.entryIdx)] idx=\(e.groupIdx) '\(e.name)'\(tag) trail=\(e.trail)")
}
print("\nTotal entries: \(events.count)")
print("Empty entries (ff trailing): \(emptyCount)")
print("Non-empty entries: \(events.count - emptyCount)")

// Now: the user's theory is that empty groups consume sentinel slots
// and push the offset. Let's see if cumulative empty count matches the offset.
// The known offset for PeepTestD is 72.
print("\n══ CUMULATIVE EMPTY COUNT AT KEY POINTS ══")
// Track: for each unique groupIdx, what's the cumulative empty count
// at the point when that group was LAST created?
var cumulativeEmpty = 0
var lastSeenCountAtIdx: [Int: Int] = [:]
for e in events {
    if e.isEmpty { cumulativeEmpty += 1 }
    lastSeenCountAtIdx[e.groupIdx] = cumulativeEmpty
}

// How many sentinel sections?
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
var sentCount = 0
if all1054.count >= 2 {
    let sc = all1054[1]; let ss=sc.dataOffset,se=ss+sc.dataSize
    let ir = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
    sentCount = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
        !ir.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.count
}
print("Sentinel count: \(sentCount)")

// Build an alternative model: sentinel ordinal = entry position in this list
// (each entry = one sentinel allocation, regardless of empty or not)
print("\n══ ALTERNATIVE MODEL: 0x2423 entry position = sentinel ordinal? ══")
print("Each 0x2423 entry allocates one sentinel. Entry position = sentinel ordinal.")
print("But there are \(events.count) entries and \(sentCount) sentinels.")

// Check: for entries where we know the answer (PeepTestD compounds 479,480,79,80 → sentinels 82,83,84,85)
// Find entries with names matching "split"
print("\nSplit-related entries:")
for e in events where e.name.contains("split") {
    print("  [\(e.entryIdx)] idx=\(e.groupIdx) '\(e.name)' empty=\(e.isEmpty)")
}

// Another model: the idx field IS the sentinel ordinal?
// idx=82 appears for 'pfx 1.grp-03' and 'NOT GREAT'
// But sentinel[82] content = "04-05T01 - Diana & Homer MWS-MS-RX9Cnct_02-03"
// That doesn't match 'pfx 1.grp-03' or 'NOT GREAT'

// Yet another model: count unique group indices
let uniqueIdxs = Set(events.map { $0.groupIdx }).sorted()
print("\nUnique group indices: \(uniqueIdxs.count) (max=\(uniqueIdxs.max() ?? -1))")

// The 0x2423 list tracks group definitions. Each unique idx = one "group slot".
// When a group is created, it gets an idx. When modified, the same idx gets a new entry.
// The ENTRY POSITION might map to the creation counter.

// Let's verify: entry[0] has idx=0, name='NG PFX' → compound[0] 'NG PFX' counter=0 ✓
// entry[1] has idx=1, name='Breaths LOW-06' → compound[1] 'Breaths LOW-06' counter=1 ✓
// Does the entry position equal the creation counter?

// Build compound counter lookup
let cmpdParents = blocks.filter{$0.contentType==0x262b}.sorted{$0.dataOffset<$1.dataOffset}
var compoundCounters: [Int: [Int]] = [:]  // ci → [counters]
for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}
    compoundCounters[ci] = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
}

print("\n══ VERIFY: Does 0x2423 entry position = 0x2523 counter? ══")
// For each entry, check if its position matches a counter for the compound at that idx
for (i, e) in events.enumerated().prefix(20) {
    let counters = compoundCounters[e.groupIdx] ?? []
    let match = counters.contains(i) ? "✓" : "✗"
    print("  entry[\(i)] idx=\(e.groupIdx) '\(e.name)' → counter \(i) in compound[\(e.groupIdx)]? \(match) (compound counters: \(counters.prefix(5))...)")
}

// Check entries near position 82
print("\n...entries near position 82:")
for i in max(0, 78)..<min(events.count, 90) {
    let e = events[i]
    let counters = compoundCounters[e.groupIdx] ?? []
    let match = counters.contains(i) ? "✓" : "✗"
    print("  entry[\(i)] idx=\(e.groupIdx) '\(e.name)'\(e.isEmpty ? " [EMPTY]" : "") → counter \(i)? \(match)")
}

print("\nDone.")
