#!/usr/bin/env swift
// sentinel_diag9.swift — Content-match including subgroup refs (b18=0x01)
import Foundation
struct Block { let contentType: UInt16; let dataOffset: Int; let dataSize: Int }
func u16(_ d: Data, at i: Int) -> UInt16 { guard i+2<=d.count else{return 0}; return UInt16(d[i])|(UInt16(d[i+1])<<8) }
func u32(_ d: Data, at i: Int) -> UInt32 { guard i+4<=d.count else{return 0}; return UInt32(d[i])|(UInt32(d[i+1])<<8)|(UInt32(d[i+2])<<16)|(UInt32(d[i+3])<<24) }
func readLE(_ d: Data, at i: Int, count: Int) -> UInt64 { var v:UInt64=0; for k in 0..<count where i+k<d.count{v|=UInt64(d[i+k])<<(k*8)}; return v }
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

func getName(_ pool: [Block], _ idx: Int) -> String {
    guard idx < pool.count else { return "?" }
    let p = pool[idx]
    let ch = blocks.filter{$0.contentType==0x2628 && $0.dataOffset>=p.dataOffset && $0.dataOffset+$0.dataSize<=p.dataOffset+p.dataSize}
    guard let nb = ch.first else { return "?" }
    let nl = Int(u32(data, at: nb.dataOffset))
    guard nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count else { return "?" }
    return String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
}

// Build sentinel sections
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
guard all1054.count >= 2 else { print("Not enough 0x1054"); exit(0) }
let sc = all1054[1]; let ss=sc.dataOffset,se=ss+sc.dataSize
let innerContainers = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
let sentinelSections = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
    !innerContainers.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.sorted{$0.dataOffset<$1.dataOffset}
print("Sentinels: \(sentinelSections.count)")

// Clip signature: set of (clipIdx, b18) tuples
struct ClipRef: Hashable { let clipIdx: Int; let isCompound: Bool }

// Pre-build sentinel clip signatures
print("Building sentinel signatures...")
var sentinelSigs: [Set<ClipRef>] = []
for sect in sentinelSections {
    let clips = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
        $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
    var sig = Set<ClipRef>()
    for clip in clips {
        let ci = Int(u16(data, at: clip.dataOffset + 2))
        let b18 = data[clip.dataOffset + 18]
        sig.insert(ClipRef(clipIdx: ci, isCompound: b18 == 0x01))
    }
    sentinelSigs.append(sig)
}

// Build compound pool signatures
func compoundSig(_ ci: Int) -> Set<ClipRef> {
    guard ci < cmpdParents.count else { return [] }
    let cmpd = cmpdParents[ci]
    let clips = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= cmpd.dataOffset &&
        $0.dataOffset + $0.dataSize <= cmpd.dataOffset + cmpd.dataSize && $0.dataSize >= 19 }
    var sig = Set<ClipRef>()
    for clip in clips {
        let ci2 = Int(u16(data, at: clip.dataOffset + 2))
        let b18 = data[clip.dataOffset + 18]
        sig.insert(ClipRef(clipIdx: ci2, isCompound: b18 == 0x01))
    }
    return sig
}

// Build compound counters for active compounds
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

var compoundCounters: [Int: [Int]] = [:]
for ci in activeCompounds {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}
    compoundCounters[ci] = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
}

// 0x2425 slot → sentinel mapping
let b2425 = blocks.filter{$0.contentType==0x2425}.sorted{$0.dataOffset<$1.dataOffset}
var counterToSlot: [Int: Int] = [:]
var slotSentinels: [[Int]] = []
for b in b2425 {
    guard b.dataSize >= 4 else { slotSentinels.append([]); continue }
    let count = Int(u32(data, at: b.dataOffset))
    var indices: [Int] = []
    var offset = 4
    for _ in 0..<count {
        guard offset + 5 <= b.dataSize else { break }
        offset += 1
        indices.append(Int(u32(data, at: b.dataOffset + offset)))
        offset += 4
    }
    slotSentinels.append(indices)
    for idx in indices { counterToSlot[idx] = b2425.firstIndex(where: { $0.dataOffset == b.dataOffset }) ?? -1 }
}

// 0x2423 slot names
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

print("\n══ CONTENT MATCHING WITH COMPOUND REFS ══")
for ci in activeCompounds.sorted() {
    let name = getName(cmpdParents, ci)
    let counters = compoundCounters[ci] ?? []
    let cSig = compoundSig(ci)

    if cSig.isEmpty {
        print("  compound[\(ci)] '\(name)' — empty signature")
        continue
    }

    // 1. Try counter as sentinel ordinal
    var counterMatch: Int? = nil
    for counter in counters where counter < sentinelSections.count {
        if sentinelSigs[counter] == cSig {
            counterMatch = counter
            break
        }
    }

    if let cm = counterMatch {
        let slot = counterToSlot[cm]
        print("  compound[\(ci)] '\(name)' → sentinel[\(cm)] ✓ COUNTER MATCH (slot=\(slot ?? -1))")
        continue
    }

    // 2. Brute-force content match
    var matches: [Int] = []
    for si in 0..<sentinelSections.count {
        if sentinelSigs[si] == cSig { matches.append(si) }
    }

    if matches.count == 1 {
        let si = matches[0]
        let slot = counterToSlot[si]
        print("  compound[\(ci)] '\(name)' → sentinel[\(si)] ✓ UNIQUE CONTENT MATCH (slot=\(slot ?? -1) '\(slotNames[slot ?? -1] ?? "?")')")
        print("    counters=\(counters)")
    } else if matches.count > 1 {
        print("  compound[\(ci)] '\(name)' → AMBIGUOUS: \(matches) (counters=\(counters))")
    } else {
        print("  compound[\(ci)] '\(name)' → NO EXACT MATCH (refs=\(cSig.count), counters=\(counters))")
        // Show what's in the compound vs nearby sentinels
        let compoundRefs = cSig.map { r in
            r.isCompound ? "cmpd[\(r.clipIdx)]:\(getName(cmpdParents, r.clipIdx))" : "audio[\(r.clipIdx)]"
        }
        print("    compound refs: \(compoundRefs.prefix(5))")
        // Check sentinel at counter ordinal if exists
        for counter in counters where counter < sentinelSections.count {
            let sSig = sentinelSigs[counter]
            let sentRefs = sSig.map { r in
                r.isCompound ? "cmpd[\(r.clipIdx)]" : "audio[\(r.clipIdx)]"
            }
            print("    sentinel[\(counter)] refs: \(sentRefs.prefix(5))")
            let overlap = cSig.intersection(sSig)
            let missing = cSig.subtracting(sSig)
            let extra = sSig.subtracting(cSig)
            print("    overlap=\(overlap.count) missing=\(missing.count) extra=\(extra.count)")
            if !missing.isEmpty {
                print("    missing from sentinel: \(missing.map{$0.isCompound ? "cmpd[\($0.clipIdx)]" : "audio[\($0.clipIdx)]"})")
            }
            if !extra.isEmpty {
                print("    extra in sentinel: \(extra.map{$0.isCompound ? "cmpd[\($0.clipIdx)]" : "audio[\($0.clipIdx)]"})")
            }
        }
    }
}

// ── For slot 77 (where compounds 79,80 land), show all owned sentinels ──
print("\n══ SLOT 77 SENTINEL DETAILS ══")
if 77 < slotSentinels.count {
    let indices = slotSentinels[77]
    print("Slot 77 '\(slotNames[77] ?? "?")' owns sentinels: \(indices)")
    for si in indices {
        let refs = sentinelSigs[si].map { r in
            r.isCompound ? "cmpd[\(r.clipIdx)]:\(getName(cmpdParents, r.clipIdx))" : "audio[\(r.clipIdx)]"
        }
        print("  sentinel[\(si)]: \(refs.prefix(8))")
    }
}

print("\nDone.")
