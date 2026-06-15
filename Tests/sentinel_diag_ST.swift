#!/usr/bin/env swift
// sentinel_diag_ST.swift — Progressive analysis of SentinelTest sessions
// Tracks 0x2423, 0x2523 counters, 0x2425 slot→sentinel, and sentinel content
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

func analyze(_ path: String) {
    guard let raw=try? Data(contentsOf:URL(fileURLWithPath:path)),
          let data=xorDecode(raw) else { print("ERROR: \(path)"); return }
    let blocks=scanBlocks(data)
    let fname = URL(fileURLWithPath: path).lastPathComponent
    print("\n" + String(repeating:"═",count:60))
    print("FILE: \(fname)")
    print(String(repeating:"═",count:60))

    let cmpdParents = blocks.filter{$0.contentType==0x262b}.sorted{$0.dataOffset<$1.dataOffset}
    let audioPool = blocks.filter{$0.contentType==0x2629}.sorted{$0.dataOffset<$1.dataOffset}

    func getNameFrom(_ pool: [Block], _ idx: Int) -> String {
        guard idx < pool.count else { return "?" }
        let p = pool[idx]
        let ch = blocks.filter{$0.contentType==0x2628 && $0.dataOffset>=p.dataOffset && $0.dataOffset+$0.dataSize<=p.dataOffset+p.dataSize}
        guard let nb = ch.first else { return "?" }
        let nl = Int(u32(data, at: nb.dataOffset))
        guard nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count else { return "?" }
        return String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
    }

    // ── Sentinel sections ──
    let all1054 = blocks.filter{$0.contentType==0x1054}.sorted{$0.dataOffset<$1.dataOffset}
    var sentinelSections: [Block] = []
    if all1054.count >= 2 {
        let sc = all1054[1]; let ss=sc.dataOffset,se=ss+sc.dataSize
        let ir = blocks.filter{$0.contentType==0x1054 && $0.dataOffset>ss && $0.dataOffset+$0.dataSize<=se}.map{($0.dataOffset,$0.dataOffset+$0.dataSize)}
        sentinelSections = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ss && b.dataOffset+b.dataSize<=se &&
            !ir.contains{r in r.0<=b.dataOffset && b.dataOffset+b.dataSize<=r.1}}.sorted{$0.dataOffset<$1.dataOffset}
    }

    // ── 0x2423 group edit history ──
    let b2423 = blocks.filter{$0.contentType==0x2423}.sorted{$0.dataOffset<$1.dataOffset}
    print("\n0x2423 entries: \(b2423.count)")
    var slotNames: [Int: String] = [:]
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
        let emptyTag = isEmpty ? " [EMPTY]" : ""
        slotNames[idx] = name
        print("  slot[\(idx)] '\(name)'\(emptyTag)")
    }

    // ── 0x2425 slot → sentinel ordinals ──
    let b2425 = blocks.filter{$0.contentType==0x2425}.sorted{$0.dataOffset<$1.dataOffset}
    print("\n0x2425 blocks: \(b2425.count)")
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
        let name = slotNames[si] ?? "?"
        print("  slot[\(si)] '\(name)' → sentinels: \(indices)")
    }

    // ── 0x2523 creation counters ──
    print("\n0x262b compounds: \(cmpdParents.count)")
    print("Sentinel sections: \(sentinelSections.count)")
    for (ci, cmpd) in cmpdParents.enumerated() {
        let name = getNameFrom(cmpdParents, ci)
        let c2523s = blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=cmpd.dataOffset && $0.dataOffset+$0.dataSize<=cmpd.dataOffset+cmpd.dataSize && $0.dataSize>=39}.sorted{$0.dataOffset<$1.dataOffset}
        let counters = c2523s.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }.sorted()
        // Get UUID bytes [21-24]
        let uuid = c2523s.first.map { hexDump(data, at: $0.dataOffset + 21, count: 4) } ?? "?"
        // Which slot owns these counters?
        let ownerSlots = Set(counters.compactMap { counterToSlot[$0] })
        let inRange = counters.filter { $0 < sentinelSections.count }
        let inTag = inRange.isEmpty ? " ✗" : " ✓"
        print("  compound[\(ci)] '\(name)' counters=\(counters)\(inTag) uuid=\(uuid) ownerSlots=\(ownerSlots.sorted())")
    }

    // ── Sentinel content ──
    print("\nSentinel content:")
    for (si, sect) in sentinelSections.enumerated() {
        let clips = blocks.filter { $0.contentType == 0x104f && $0.dataOffset >= sect.dataOffset &&
            $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize && $0.dataSize >= 19 }
        let descs = clips.map { clip -> String in
            let ci = Int(u16(data, at: clip.dataOffset + 2))
            let b18 = data[clip.dataOffset + 18]
            let pos = readLE(data, at: clip.dataOffset + 7, count: 8)
            let relOff = pos >= 1_000_000_000_000 ? Int64(bitPattern: pos - 1_000_000_000_000) : Int64(bitPattern: pos)
            let name = b18 == 0x00 ? getNameFrom(audioPool, ci) : getNameFrom(cmpdParents, ci)
            return "[\(b18==0x00 ? "A" : "C"):\(ci):\(name)@\(relOff)]"
        }
        let ownerSlot = counterToSlot[si]
        let ownerName = ownerSlot != nil ? slotNames[ownerSlot!] ?? "?" : "NONE"
        print("  sentinel[\(si)] slot=\(ownerSlot ?? -1) '\(ownerName)': \(descs)")
    }

    // ── Active timeline compound placements ──
    let activeContainer = all1054.first
    if let ac = activeContainer {
        let acSects = blocks.filter{b in b.contentType==0x1052 && b.dataOffset>=ac.dataOffset && b.dataOffset+b.dataSize<=ac.dataOffset+ac.dataSize}.sorted{$0.dataOffset<$1.dataOffset}
        var compoundPlacements: [(sec: Int, ci: Int, name: String, counter: Int?, sentinel: Int?)] = []
        for (si, sect) in acSects.enumerated() {
            let refs = blocks.filter{$0.contentType==0x104f && $0.dataOffset>=sect.dataOffset && $0.dataOffset+$0.dataSize<=sect.dataOffset+sect.dataSize && $0.dataSize>=19}
            for ref in refs where data[ref.dataOffset+18] == 0x01 {
                let ci = Int(u16(data, at: ref.dataOffset + 2))
                let name = getNameFrom(cmpdParents, ci)
                let cmpd = ci < cmpdParents.count ? cmpdParents[ci] : nil
                let c2523 = cmpd.flatMap { c in blocks.filter{$0.contentType==0x2523 && $0.dataOffset>=c.dataOffset && $0.dataOffset+$0.dataSize<=c.dataOffset+c.dataSize && $0.dataSize>=39}.first }
                let counter = c2523.map { Int(readLE(data, at: $0.dataOffset + 37, count: 2)) }
                let sentinel = counter.flatMap { c in c < sentinelSections.count ? c : nil }
                compoundPlacements.append((si, ci, name, counter, sentinel))
            }
        }
        if !compoundPlacements.isEmpty {
            print("\nActive compound placements:")
            for p in compoundPlacements {
                let sentTag = p.sentinel != nil ? "→ sentinel[\(p.sentinel!)]" : "→ NO SENTINEL (counter=\(p.counter ?? -1))"
                print("  sect[\(p.sec)] compound[\(p.ci)] '\(p.name)' counter=\(p.counter ?? -1) \(sentTag)")
            }
        }
    }
}

// Analyze all sessions
let args = CommandLine.arguments.dropFirst()
if args.isEmpty {
    // Default: all SentinelTest sessions
    let sessions = [
        "Tests2/SentinelTest_01_baseline.ptx",
        "Tests2/SentinelTest_02_twogroups.ptx",
        "Tests2/SentinelTest_03_emptygroup.ptx",
        "Tests2/SentinelTest_04_thirdgroup.ptx",
        "Tests2/SentinelTest_05_split.ptx",
        "Tests2/SentinelTest_06_regroup.ptx",
    ]
    for s in sessions { analyze(s) }
} else {
    for a in args { analyze(a) }
}
print("\nDone.")
