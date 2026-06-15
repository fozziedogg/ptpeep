#!/usr/bin/env swift
// sentinel_diag5.swift — Examine unexplored block types: 0x2423, 0x1029, 0x4826, 0x2077
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

// ── A. 0x2423 clip group directory ──
print("══ A. 0x2423 CLIP GROUP DIRECTORY ══")
let b2423 = blocks.filter{$0.contentType==0x2423}.sorted{$0.dataOffset<$1.dataOffset}
print("Count: \(b2423.count)")

// Parse: [index u32] [nameLen u32] [name] [trailing]
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
    let trail = trailLen > 0 ? hexDump(data, at: trailStart, count: min(trailLen, 20)) : "(none)"

    // Print all entries for small files, or interesting ones for large
    guard b2423.count < 30 || i < 10 || [82, 83, 84, 85].contains(idx) ||
          name.contains("split") || i >= b2423.count - 5 else { continue }

    print("  [\(i)] idx=\(idx) '\(name)' trailing(\(trailLen)b): \(trail)")
}

// ── B. 0x1029 blocks (491 count ≈ 493 sentinels) ──
print("\n══ B. 0x1029 BLOCKS ══")
let b1029 = blocks.filter{$0.contentType==0x1029}.sorted{$0.dataOffset<$1.dataOffset}
print("Count: \(b1029.count)")
// Dump first few and ones near index 82
for (i, b) in b1029.enumerated() {
    guard i < 5 || (i >= 80 && i <= 86) || i >= b1029.count - 3 else { continue }
    print("  [\(i)] size=\(b.dataSize) raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 60)))")
    // Check for any u16 values 82-85
    for off in 0..<(b.dataSize-1) {
        let v = Int(u16(data, at: b.dataOffset + off))
        if v >= 82 && v <= 85 && i >= 80 && i <= 86 {
            // don't print, too noisy
        }
    }
}

// ── C. 0x4826 blocks (593 count ≈ total sections) ──
print("\n══ C. 0x4826 BLOCKS ══")
let b4826 = blocks.filter{$0.contentType==0x4826}.sorted{$0.dataOffset<$1.dataOffset}
print("Count: \(b4826.count)")
for (i, b) in b4826.enumerated() {
    guard i < 5 || (i >= 80 && i <= 90) || (i >= 168 && i <= 172) else { continue }
    print("  [\(i)] size=\(b.dataSize) raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 60)))")
}

// ── D. 0x2077 blocks (296 count) ──
print("\n══ D. 0x2077 BLOCKS ══")
let b2077 = blocks.filter{$0.contentType==0x2077}.sorted{$0.dataOffset<$1.dataOffset}
print("Count: \(b2077.count)")
for (i, b) in b2077.enumerated() {
    guard i < 5 || (i >= 80 && i <= 86) else { continue }
    print("  [\(i)] size=\(b.dataSize) raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 60)))")
}

// ── E. 0x1021 blocks (588 count — very close to 589 total 0x1052 sections!) ──
print("\n══ E. 0x1021 BLOCKS (588 ≈ 589 sections) ══")
let b1021 = blocks.filter{$0.contentType==0x1021}.sorted{$0.dataOffset<$1.dataOffset}
print("Count: \(b1021.count)")
// These might be section descriptors with mapping info
for (i, b) in b1021.enumerated() {
    guard i < 5 || (i >= 80 && i <= 90) || (i >= 168 && i <= 172) else { continue }
    print("  [\(i)] size=\(b.dataSize) raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 60)))")
}

// ── F. 0x260d blocks (491 — same as 0x1029, very close to sentinel count!) ──
print("\n══ F. 0x260d BLOCKS (491 ≈ 493 sentinels) ══")
let b260d = blocks.filter{$0.contentType==0x260d}.sorted{$0.dataOffset<$1.dataOffset}
print("Count: \(b260d.count)")
for (i, b) in b260d.enumerated() {
    guard i < 5 || (i >= 80 && i <= 86) else { continue }
    print("  [\(i)] size=\(b.dataSize) raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 60)))")
}

// ── G. Sentinel section — do they have NON-0x104f/0x1050 children? ──
print("\n══ G. SENTINEL SECTION NON-CLIP CHILDREN ══")
let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
guard all1054.count >= 2 else { exit(0) }
let sc = all1054[1]; let ss=sc.dataOffset,se=ss+sc.dataSize
let ir = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
let sentinelSections = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
    !ir.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.sorted{$0.dataOffset<$1.dataOffset}

print("Checking sentinel sections for non-104f/1050 children...")
var foundNonClip = false
for (i, sect) in sentinelSections.enumerated() {
    let ch = blocks.filter{$0.dataOffset>sect.dataOffset && $0.dataOffset+$0.dataSize<=sect.dataOffset+sect.dataSize}
    let nonClip = ch.filter{$0.contentType != 0x104f && $0.contentType != 0x1050}
    if !nonClip.isEmpty {
        foundNonClip = true
        print("  sentinel[\(i)]: \(nonClip.count) non-clip children: \(nonClip.map{"0x\(String(format:"%04x",$0.contentType))"}.joined(separator:", "))")
        for nc in nonClip {
            print("    0x\(String(format:"%04x",nc.contentType)) size=\(nc.dataSize) raw: \(hexDump(data, at: nc.dataOffset, count: min(nc.dataSize, 40)))")
        }
        if i > 90 && !([82,83,84,85,164,165,166,167].contains(i)) { break }
    }
}
if !foundNonClip { print("  None found — sentinel sections only contain 0x104f/0x1050") }

// ── H. What's INSIDE the sentinel 0x1054 container besides 0x1052 sections? ──
print("\n══ H. SENTINEL CONTAINER CHILDREN (non-0x1052) ══")
let sentChildren = blocks.filter{$0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se && $0.contentType != 0x1052 && $0.contentType != 0x104f && $0.contentType != 0x1050 && $0.contentType != 0x1054}
var sentChildTypes: [UInt16: Int] = [:]
for b in sentChildren { sentChildTypes[b.contentType, default: 0] += 1 }
print("Non-section block types inside sentinel container:")
for (ct, count) in sentChildTypes.sorted(by:{$0.key<$1.key}) {
    print("  0x\(String(format:"%04x",ct)): \(count)")
}
for b in sentChildren.prefix(10) {
    print("  0x\(String(format:"%04x",b.contentType)) size=\(b.dataSize) raw: \(hexDump(data, at: b.dataOffset, count: min(b.dataSize, 40)))")
}

print("\nDone.")
