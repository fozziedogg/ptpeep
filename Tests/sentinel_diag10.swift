#!/usr/bin/env swift
// sentinel_diag10.swift — Check 0x2523 bytes[33-34] as alternative sentinel ordinal
// and examine all bytes of 0x2523 for out-of-range compounds
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

// Build sentinel sections
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
guard all1054.count >= 2 else { print("Not enough 0x1054"); exit(0) }
let sentCount: Int = {
    let sc = all1054[1]; let ss=sc.dataOffset,se=ss+sc.dataSize
    let ir = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
    return blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
        !ir.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.count
}()
print("Sentinel count: \(sentCount)")

// Find active compounds
let activeContainer = all1054[0]
let activeSections = blocks.filter { b in
    b.contentType == 0x1052 && b.dataOffset >= activeContainer.dataOffset &&
    b.dataOffset + b.dataSize <= activeContainer.dataOffset + activeContainer.dataSize
}.sorted { $0.dataOffset < $1.dataOffset }

var activeCompounds = Set<Int>()
for sect in activeSections {
    let refs = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
        $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
    for ref in refs where data[ref.dataOffset + 18] == 0x01 {
        activeCompounds.insert(Int(u16(data, at: ref.dataOffset + 2)))
    }
}

print("Active compounds: \(activeCompounds.count)")
print("\n══ 0x2523 FULL DUMP FOR ACTIVE COMPOUNDS ══")

for ci in activeCompounds.sorted() {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}.sorted{$0.dataOffset<$1.dataOffset}

    let name = getName(ci)
    print("\ncompound[\(ci)] '\(name)' — \(c2523s.count) 0x2523 children")

    for (j, c) in c2523s.enumerated() {
        let counter37 = Int(readLE(data, at: c.dataOffset + 37, count: 2))
        let alt33 = Int(readLE(data, at: c.dataOffset + 33, count: 2))
        let inRange = counter37 < sentCount ? "✓" : "✗"

        print("  0x2523[\(j)] size=\(c.dataSize)")
        print("    bytes[33..34] = \(alt33)  bytes[37..38] = \(counter37) \(inRange)")
        print("    raw: \(hexDump(data, at: c.dataOffset, count: min(c.dataSize, 50)))")

        // Check every u16 in the block for values in sentinel range
        var sentRangeValues: [(Int, Int)] = []  // (offset, value)
        for off in stride(from: 0, to: c.dataSize - 1, by: 2) {
            let v = Int(u16(data, at: c.dataOffset + off))
            if v > 0 && v < sentCount && v != counter37 && v != alt33 {
                sentRangeValues.append((off, v))
            }
        }
        if !sentRangeValues.isEmpty {
            print("    other u16 in sentinel range: \(sentRangeValues.map{"@\($0.0)=\($0.1)"}.joined(separator: ", "))")
        }
    }
}

// ── Also check: for multi-0x2523 compounds, dump the first and last ──
print("\n\n══ MULTI-0x2523 COMPOUNDS (sample) ══")
// Find compounds with many 0x2523 children that have both in-range and out-of-range counters
for ci in 0..<cmpdParents.count {
    let cmpd = cmpdParents[ci]
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}.sorted{$0.dataOffset<$1.dataOffset}
    guard c2523s.count >= 3 else { continue }

    let counters = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
    let alts = c2523s.map { Int(readLE(data, at: $0.dataOffset + 33, count: 2)) }.sorted()
    let inRange = counters.filter { $0 < sentCount }
    let outRange = counters.filter { $0 >= sentCount }

    // Only show compounds that span the boundary
    guard !inRange.isEmpty && !outRange.isEmpty else { continue }

    let name = getName(ci)
    print("\ncompound[\(ci)] '\(name)' — \(c2523s.count) events")
    print("  counter range: \(counters.first!)...\(counters.last!)")
    print("  in-range: \(inRange.count) (\(inRange.first!)...\(inRange.last!))")
    print("  out-of-range: \(outRange.count) (\(outRange.first!)...\(outRange.last!))")
    print("  alt33 range: \(alts.first!)...\(alts.last!)")

    // Show first and last 0x2523
    let first = c2523s.first!
    let last = c2523s.last!
    print("  first: bytes[33..34]=\(Int(readLE(data, at: first.dataOffset + 33, count: 2))) bytes[37..38]=\(Int(readLE(data, at: first.dataOffset + 37, count: 2)))")
    print("    raw: \(hexDump(data, at: first.dataOffset, count: min(first.dataSize, 50)))")
    print("  last:  bytes[33..34]=\(Int(readLE(data, at: last.dataOffset + 33, count: 2))) bytes[37..38]=\(Int(readLE(data, at: last.dataOffset + 37, count: 2)))")
    print("    raw: \(hexDump(data, at: last.dataOffset, count: min(last.dataSize, 50)))")

    if c2523s.count > 30 { break }  // Limit output
}

print("\nDone.")
