#!/usr/bin/env swift
// sentinel_diag11.swift — Dump active 0x104f placement bytes for compound clips
// Check if the placement itself stores the sentinel ordinal
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
guard all1054.count >= 2 else { print("Not enough 0x1054"); exit(0) }
let sentSc = all1054[1]; let sentSs=sentSc.dataOffset, sentSe=sentSs+sentSc.dataSize
let innerContainers = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>sentSs && $0.dataOffset+$0.dataSize<=sentSe}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
let sentinelSections = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=sentSs && b.dataOffset+b.dataSize<=sentSe &&
    !innerContainers.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.sorted{$0.dataOffset<$1.dataOffset}
let sentCount = sentinelSections.count
print("Sentinel count: \(sentCount)")

// Build compound counters
var compoundCounters: [Int: [Int]] = [:]
for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}
    if !c2523s.isEmpty {
        compoundCounters[ci] = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
    }
}

// Active container
let activeContainer = all1054[0]
let activeSections = blocks.filter { b in
    b.contentType == 0x1052 && b.dataOffset >= activeContainer.dataOffset &&
    b.dataOffset + b.dataSize <= activeContainer.dataOffset + activeContainer.dataSize
}.sorted { $0.dataOffset < $1.dataOffset }

print("\n══ ACTIVE 0x104f PLACEMENTS (b18=0x01) — FULL DUMP ══")
for (secIdx, sect) in activeSections.enumerated() {
    let refs = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
        $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
    for ref in refs where data[ref.dataOffset + 18] == 0x01 {
        let ci = Int(u16(data, at: ref.dataOffset + 2))
        let name = getName(ci)
        let counters = compoundCounters[ci] ?? []
        let firstCounter = counters.first ?? -1
        let inRange = firstCounter < sentCount ? "✓" : "✗"

        // Dump all placement bytes
        print("\nsection[\(secIdx)] compound[\(ci)] '\(name)' counter=\(firstCounter) \(inRange)")
        print("  full (\(ref.dataSize)b): \(hexDump(data, at: ref.dataOffset, count: ref.dataSize))")

        // Parse key fields
        let b0_1 = Int(u16(data, at: ref.dataOffset))
        let clipIdx = Int(u16(data, at: ref.dataOffset + 2))
        let b4_6 = hexDump(data, at: ref.dataOffset + 4, count: 3)
        let pos = readLE(data, at: ref.dataOffset + 7, count: 8)
        let b15_17 = hexDump(data, at: ref.dataOffset + 15, count: 3)
        let b18 = data[ref.dataOffset + 18]
        let b19_32 = ref.dataSize >= 33 ? hexDump(data, at: ref.dataOffset + 19, count: 14) : ""
        let b33_34 = ref.dataSize >= 35 ? Int(u16(data, at: ref.dataOffset + 33)) : -1
        let b35 = ref.dataSize >= 36 ? Int(data[ref.dataOffset + 35]) : -1
        let b36_37 = ref.dataSize >= 38 ? Int(u16(data, at: ref.dataOffset + 36)) : -1
        let b38 = ref.dataSize >= 39 ? Int(data[ref.dataOffset + 38]) : -1

        print("  parsed: b[0-1]=\(b0_1) ci=\(clipIdx) b[4-6]=\(b4_6) pos=\(pos)")
        print("  b[15-17]=\(b15_17) b18=\(b18) b[19-32]=\(b19_32)")
        print("  b[33-34]=\(b33_34) b35=\(b35) b[36-37]=\(b36_37) b38=\(b38)")

        // Check every u16 in the placement for sentinel-range values
        var sentCandidates: [(Int, Int)] = []
        for off in stride(from: 0, to: ref.dataSize - 1, by: 1) {
            let v = Int(u16(data, at: ref.dataOffset + off))
            if v > 0 && v < sentCount && v != clipIdx {
                sentCandidates.append((off, v))
            }
        }
        if !sentCandidates.isEmpty {
            print("  u16 in sentinel range: \(sentCandidates.map{"@\($0.0)=\($0.1)"}.joined(separator: ", "))")
        }
    }
}

print("\nDone.")
