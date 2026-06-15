#!/usr/bin/env swift
// sentinel_diag4.swift — Look EVERYWHERE we haven't looked yet
// 1. All block types in the file (what haven't we examined?)
// 2. Active 0x1052 section headers (do they point to sentinel sections?)
// 3. 0x1050 wrapper blocks (do they carry mapping metadata?)
// 4. Blocks near/between the two 0x1054 containers
// 5. Any block type that contains the values 82-85 as u16 at consistent offsets
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
    return bs.filter{$0.dataOffset>p.dataOffset && $0.dataOffset+$0.dataSize<=e}
}

guard CommandLine.arguments.count>1 else{print("Usage: ...");exit(1)}
guard let raw=try? Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])) else{print("err");exit(1)}
guard let data=xorDecode(raw) else{print("xor err");exit(1)}
let blocks=scanBlocks(data)
print("Total blocks: \(blocks.count)")

// ── 1. All block types ──
print("\n══ 1. ALL BLOCK TYPES IN FILE ══")
var typeCounts: [UInt16: Int] = [:]
for b in blocks { typeCounts[b.contentType, default: 0] += 1 }
for (ct, count) in typeCounts.sorted(by: { $0.key < $1.key }) {
    print("  0x\(String(format: "%04x", ct)): \(count)")
}

// ── 2. Active 0x1052 section headers ──
print("\n══ 2. ACTIVE 0x1052 SECTION HEADERS ══")
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
guard all1054.count >= 2 else { print("Not enough 0x1054"); exit(0) }

let activeContainer = all1054[0]
let acStart = activeContainer.dataOffset, acEnd = acStart + activeContainer.dataSize
let activeSections = blocks.filter { b in
    b.contentType == 0x1052 && b.dataOffset >= acStart && b.dataOffset + b.dataSize <= acEnd
}.sorted { $0.dataOffset < $1.dataOffset }

print("Active sections: \(activeSections.count)")
// Show headers for sections that contain b18=0x01 compounds (sections 10-13 are our targets)
for (idx, sect) in activeSections.enumerated() {
    // Check if this section has b18=0x01 compounds
    let refs = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset && $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize }
    var hasCompound = false
    for ref in refs where ref.dataSize >= 19 {
        let tl = readLE(data, at: ref.dataOffset + 7, count: 8)
        if tl < 1_000_000_000_000 && data[ref.dataOffset + 18] == 0x01 { hasCompound = true; break }
    }

    // Get section name (from first 0x1014 or 0x1034 child)
    let nameBlocks = blocks.filter { ($0.contentType == 0x1014 || $0.contentType == 0x1034) &&
        $0.dataOffset >= sect.dataOffset && $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize }

    // Only print sections with compounds, plus first few
    guard hasCompound || idx < 3 else { continue }

    // Dump the raw header bytes (before first child block)
    let firstChild = children(of: sect, in: blocks).sorted { $0.dataOffset < $1.dataOffset }.first
    let headerEnd = firstChild.map { $0.dataOffset - 9 } ?? (sect.dataOffset + min(sect.dataSize, 40))
    let headerLen = headerEnd - sect.dataOffset

    let tag = hasCompound ? " [HAS COMPOUNDS]" : ""
    print("  activeSection[\(idx)]\(tag): headerLen=\(headerLen)")
    print("    header: \(hexDump(data, at: sect.dataOffset, count: min(headerLen, 60)))")
    print("    raw40:  \(hexDump(data, at: sect.dataOffset, count: min(40, sect.dataSize)))")
}

// ── 3. 0x1050 wrappers around active compound 0x104f placements ──
print("\n══ 3. 0x1050 WRAPPERS AROUND COMPOUND PLACEMENTS ══")
let cmpdParents = blocks.filter{$0.contentType==0x262b}.sorted{$0.dataOffset<$1.dataOffset}

for (secIdx, sect) in activeSections.enumerated() {
    let refs = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset && $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize }
    for ref in refs where ref.dataSize >= 19 {
        let tl = readLE(data, at: ref.dataOffset + 7, count: 8)
        guard tl < 1_000_000_000_000, data[ref.dataOffset + 18] == 0x01 else { continue }
        let clipIdx = Int(u16(data, at: ref.dataOffset + 2))

        // Find parent 0x1050 wrapper
        let wrappers = blocks.filter { $0.contentType == 0x1050 &&
            $0.dataOffset <= ref.dataOffset - 9 &&
            $0.dataOffset + $0.dataSize >= ref.dataOffset + ref.dataSize }
            .sorted { $0.dataSize < $1.dataSize }  // smallest containing = immediate parent

        guard let wrapper = wrappers.first else { continue }

        // How much extra data is in the wrapper beyond the 0x104f?
        let wrapperChildren = children(of: wrapper, in: blocks)
        let otherChildren = wrapperChildren.filter { $0.contentType != 0x104f }

        // Only print a few interesting ones
        guard [10, 11, 12, 13, 92, 93].contains(secIdx) else { continue }

        var name = "?"
        if clipIdx < cmpdParents.count {
            let ch = children(of: cmpdParents[clipIdx], in: blocks)
            if let nb = ch.first(where: { $0.contentType == 0x2628 }) {
                let nl = Int(u32(data, at: nb.dataOffset))
                if nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count {
                    name = String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
                }
            }
        }

        print("  section[\(secIdx)] ci=\(clipIdx) '\(name)'")
        print("    0x1050 wrapper: size=\(wrapper.dataSize), children: \(wrapperChildren.count) (\(wrapperChildren.map { "0x\(String(format: "%04x", $0.contentType))" }.joined(separator: ", ")))")
        if !otherChildren.isEmpty {
            for oc in otherChildren {
                print("    ** NON-104f child: 0x\(String(format: "%04x", oc.contentType)) size=\(oc.dataSize)")
                print("       raw: \(hexDump(data, at: oc.dataOffset, count: min(oc.dataSize, 40)))")
            }
        }
        // Dump wrapper content BEFORE the 0x104f child
        let preBytes = ref.dataOffset - 9 - wrapper.dataOffset  // -9 for 0x104f's block header
        if preBytes > 0 {
            print("    wrapper pre-104f bytes (\(preBytes)): \(hexDump(data, at: wrapper.dataOffset, count: min(preBytes, 40)))")
        }
    }
}

// ── 4. Blocks BETWEEN the two 0x1054 containers ──
print("\n══ 4. BLOCKS BETWEEN ACTIVE AND SENTINEL CONTAINERS ══")
let activeEnd = activeContainer.dataOffset + activeContainer.dataSize
let sentContainer = all1054[1]
let sentStart = sentContainer.dataOffset

let betweenBlocks = blocks.filter { $0.dataOffset >= activeEnd && $0.dataOffset < sentStart }
print("Gap between containers: \(sentStart - activeEnd) bytes, \(betweenBlocks.count) blocks")
var betweenTypes: [UInt16: Int] = [:]
for b in betweenBlocks { betweenTypes[b.contentType, default: 0] += 1 }
for (ct, count) in betweenTypes.sorted(by: { $0.key < $1.key }) {
    print("  0x\(String(format: "%04x", ct)): \(count)")
}
// Show first few
for b in betweenBlocks.prefix(10) {
    print("  offset=\(b.dataOffset) type=0x\(String(format: "%04x", b.contentType)) size=\(b.dataSize)")
    print("    raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 40)))")
}

// ── 5. Search for a MAPPING TABLE ──
// Look for any block that contains compound pool index 479 near sentinel ordinal 82
print("\n══ 5. SEARCH FOR MAPPING TABLE ══")
print("Looking for blocks containing u16 pairs (479,82), (480,83), (79,84), (80,85)")

let pairs: [(Int, Int)] = [(479, 82), (480, 83), (79, 84), (80, 85)]
var candidateBlocks: [Block] = []

for b in blocks {
    guard b.dataSize >= 8 else { continue }
    // Skip the block types we already know about
    let skipTypes: Set<UInt16> = [0x104f, 0x1050, 0x2629, 0x262b, 0x2628, 0x2523, 0x2526, 0x1052]
    guard !skipTypes.contains(b.contentType) else { continue }

    var matchCount = 0
    for (ci, sent) in pairs {
        // Look for ci as u16 followed by sent as u16 within 8 bytes
        for off in 0..<(b.dataSize - 3) {
            let v1 = Int(u16(data, at: b.dataOffset + off))
            if v1 == ci {
                // Check if sent appears within next 8 bytes
                for off2 in (off+2)..<min(off+10, b.dataSize-1) {
                    let v2 = Int(u16(data, at: b.dataOffset + off2))
                    if v2 == sent { matchCount += 1; break }
                }
            }
        }
    }
    if matchCount >= 2 {
        candidateBlocks.append(b)
        print("  MATCH (\(matchCount)/4): type=0x\(String(format: "%04x", b.contentType)) offset=\(b.dataOffset) size=\(b.dataSize)")
        print("    raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 80)))")
    }
}
if candidateBlocks.isEmpty { print("  (no mapping table found with paired search)") }

// ── 6. Look for blocks containing value 82 near the active sections that have compounds ──
// Maybe the mapping is stored per-section, not per-compound
print("\n══ 6. ACTIVE SECTION INTERNAL STRUCTURE ══")
print("What non-104f/1050 blocks live inside active sections with compounds?")

for (secIdx, sect) in activeSections.enumerated() {
    guard [10, 11, 12, 13].contains(secIdx) else { continue }

    let allChildren = children(of: sect, in: blocks)
    let nonClipChildren = allChildren.filter { $0.contentType != 0x104f && $0.contentType != 0x1050 }

    print("  activeSection[\(secIdx)]: \(allChildren.count) children total, \(nonClipChildren.count) non-clip")
    for ch in nonClipChildren {
        print("    0x\(String(format: "%04x", ch.contentType)) size=\(ch.dataSize)")
        print("      raw: \(hexDump(data, at: ch.dataOffset, count: min(ch.dataSize, 60)))")
        // Check for sentinel ordinals
        for off in 0..<(ch.dataSize - 1) {
            let v = Int(u16(data, at: ch.dataOffset + off))
            if v == secIdx + 72 {
                print("      ** u16@[\(off)] = \(v) = secIdx+72!")
            }
        }
    }
}

// ── 7. What block types contain the sentinel container? ──
print("\n══ 7. PARENT/SIBLING BLOCKS OF SENTINEL CONTAINER ══")
let sentEnd = sentContainer.dataOffset + sentContainer.dataSize
let containingBlocks = blocks.filter { $0.dataOffset < sentContainer.dataOffset - 9 &&
    $0.dataOffset + $0.dataSize >= sentEnd }.sorted { $0.dataSize < $1.dataSize }
for b in containingBlocks.prefix(5) {
    print("  type=0x\(String(format: "%04x", b.contentType)) offset=\(b.dataOffset) size=\(b.dataSize)")
}

// Siblings just after sentinel container
let afterSent = blocks.filter { $0.dataOffset >= sentEnd }.sorted { $0.dataOffset < $1.dataOffset }
print("\nFirst 10 blocks after sentinel container:")
for b in afterSent.prefix(10) {
    print("  type=0x\(String(format: "%04x", b.contentType)) offset=\(b.dataOffset) size=\(b.dataSize)")
    print("    raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 40)))")
}

print("\nDone.")
