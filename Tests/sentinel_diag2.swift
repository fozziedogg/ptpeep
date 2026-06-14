#!/usr/bin/env swift
// sentinel_diag2.swift — Deep dive into 0x2523/0x2526 blocks and multi-child compounds
// Looking for: the sentinel ordinal hidden in compound metadata
// Usage: swift sentinel_diag2.swift <file.ptx>

import Foundation

struct Block {
    let contentType: UInt16
    let dataOffset: Int
    let dataSize: Int
}

func u16(_ d: Data, at i: Int) -> UInt16 {
    guard i + 2 <= d.count else { return 0 }
    return UInt16(d[i]) | (UInt16(d[i+1]) << 8)
}
func u32(_ d: Data, at i: Int) -> UInt32 {
    guard i + 4 <= d.count else { return 0 }
    return UInt32(d[i]) | (UInt32(d[i+1]) << 8) | (UInt32(d[i+2]) << 16) | (UInt32(d[i+3]) << 24)
}
func readLE(_ d: Data, at i: Int, count: Int) -> UInt64 {
    var v: UInt64 = 0
    for k in 0..<count where i+k < d.count { v |= UInt64(d[i+k]) << (k*8) }
    return v
}
func hexDump(_ d: Data, at offset: Int, count: Int) -> String {
    let end = min(offset + count, d.count)
    guard offset < end else { return "(empty)" }
    return (offset..<end).map { String(format: "%02x", d[$0]) }.joined(separator: " ")
}

func xorDecode(_ raw: Data) -> Data? {
    guard raw.count > 0x14 else { return nil }
    let fileType = raw[0x12]; let xorValue = raw[0x13]
    let mul: UInt16; let negative: Bool
    switch fileType {
    case 0x05: mul = 11; negative = true
    case 0x01: mul = 53; negative = false
    default: return nil
    }
    var delta: UInt8 = 0
    for i: UInt16 in 0...255 {
        if (i * mul) & 0xff == UInt16(xorValue) {
            delta = negative ? UInt8(truncatingIfNeeded: 256 &- Int(i)) : UInt8(i); break
        }
    }
    var table = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var decoded = raw
    if fileType == 0x05 {
        for chunk in stride(from: 4096, to: raw.count, by: 4096) {
            let xb = table[(chunk >> 12) & 0xff]; guard xb != 0 else { continue }
            let end = min(chunk + 4096, raw.count)
            for i in chunk..<end { decoded[i] = raw[i] ^ xb }
        }
    } else { for i in 0..<raw.count { decoded[i] = raw[i] ^ table[i & 0xff] } }
    return decoded
}

func scanBlocks(_ data: Data) -> [Block] {
    var blocks = [Block]()
    var i = 0x1f
    while i + 9 <= data.count {
        guard data[i] == 0x5a else { i += 1; continue }
        let size = Int(u32(data, at: i + 3))
        let ct = u16(data, at: i + 7)
        guard size > 0, size < 50_000_000, i + 9 + size <= data.count else { i += 1; continue }
        blocks.append(Block(contentType: ct, dataOffset: i + 9, dataSize: size))
        i += 1
    }
    return blocks
}

func childBlocks(of parent: Block, in blocks: [Block]) -> [Block] {
    let pEnd = parent.dataOffset + parent.dataSize
    return blocks.filter { $0.dataOffset >= parent.dataOffset && $0.dataOffset + $0.dataSize <= pEnd && $0.dataOffset != parent.dataOffset }
}

guard CommandLine.arguments.count > 1 else { print("Usage: swift sentinel_diag2.swift <file.ptx>"); exit(1) }
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else { print("Cannot read"); exit(1) }
guard let data = xorDecode(raw) else { print("XOR failed"); exit(1) }
let blocks = scanBlocks(data)

let cmpdParents = blocks.filter { $0.contentType == 0x262b }.sorted { $0.dataOffset < $1.dataOffset }
let audioParents = blocks.filter { $0.contentType == 0x2629 }.sorted { $0.dataOffset < $1.dataOffset }
print("Compounds: \(cmpdParents.count), Audio: \(audioParents.count)")

// ── A. Full 0x2523 dumps for known-answer compounds ──
print("\n══════════════════════════════════════════")
print("A. FULL 0x2523 AND 0x2526 DUMPS")
print("══════════════════════════════════════════")
print("Target: compounds 79,80,479,480 should map to sentinels 82,83,84,85")

let targets = [0, 1, 2, 3, 4, 68, 79, 80, 155, 180, 233, 234, 253, 331, 479, 480]
for ci in targets {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let children = childBlocks(of: cmpd, in: blocks)

    // Name
    var name = "?"
    if let nb = children.first(where: { $0.contentType == 0x2628 }) {
        let nl = Int(u32(data, at: nb.dataOffset))
        if nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count {
            name = String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
        }
    }

    let c2523s = children.filter { $0.contentType == 0x2523 }
    let c2526s = children.filter { $0.contentType == 0x2526 }
    print("\n  compound[\(ci)] '\(name)' — \(c2523s.count) x 0x2523, \(c2526s.count) x 0x2526")

    for (j, m) in c2523s.enumerated() {
        print("    0x2523[\(j)] size=\(m.dataSize):")
        // Dump ALL bytes
        let dumpLen = min(m.dataSize, 60)
        print("      raw: \(hexDump(data, at: m.dataOffset, count: dumpLen))")
        if m.dataSize >= 39 {
            let counter = Int(readLE(data, at: m.dataOffset + 37, count: 2))
            print("      bytes[37..38] counter = \(counter)")
        }
        if m.dataSize >= 43 {
            let val39 = u32(data, at: m.dataOffset + 39)
            print("      bytes[39..42] = \(val39) (audio ci?)")
        }
        // Check every 2-byte window for values 82-85 (known sentinel ordinals)
        var matches82_85: [String] = []
        for off in 0..<(m.dataSize - 1) {
            let v = Int(u16(data, at: m.dataOffset + off))
            if v >= 82 && v <= 85 {
                matches82_85.append("u16@[\(off)]=\(v)")
            }
        }
        if !matches82_85.isEmpty && [79,80,479,480].contains(ci) {
            print("      ** MATCHES 82-85: \(matches82_85.joined(separator: ", "))")
        }
    }

    for (j, r) in c2526s.enumerated() {
        print("    0x2526[\(j)] size=\(r.dataSize):")
        print("      raw: \(hexDump(data, at: r.dataOffset, count: min(r.dataSize, 40)))")
    }

    // Any other unusual children
    let unusual = children.filter { $0.contentType != 0x2628 && $0.contentType != 0x2523 && $0.contentType != 0x2526 }
    for ch in unusual {
        print("    UNUSUAL 0x\(String(format: "%04x", ch.contentType)) size=\(ch.dataSize):")
        print("      raw: \(hexDump(data, at: ch.dataOffset, count: min(ch.dataSize, 40)))")
    }
}

// ── B. Compounds with MULTIPLE 0x2523 children ──
print("\n══════════════════════════════════════════")
print("B. COMPOUNDS WITH MULTIPLE 0x2523 CHILDREN")
print("══════════════════════════════════════════")

var multiCount = 0
for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = childBlocks(of: cmpd, in: blocks).filter { $0.contentType == 0x2523 }
    guard c2523s.count > 1 else { continue }
    multiCount += 1

    var name = "?"
    if let nb = childBlocks(of: cmpd, in: blocks).first(where: { $0.contentType == 0x2628 }) {
        let nl = Int(u32(data, at: nb.dataOffset))
        if nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count {
            name = String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
        }
    }

    let counters = c2523s.compactMap { m -> Int? in
        guard m.dataSize >= 39 else { return nil }
        return Int(readLE(data, at: m.dataOffset + 37, count: 2))
    }

    if multiCount <= 30 || [79,80,479,480].contains(ci) {
        print("  compound[\(ci)] '\(name)' counters=\(counters)")
    }
}
print("Total compounds with multiple 0x2523: \(multiCount)")

// ── C. For each compound, try matching FIRST 0x2523 counter vs LAST ──
print("\n══════════════════════════════════════════")
print("C. FIRST vs LAST 0x2523 COUNTER (for multi-0x2523 compounds)")
print("══════════════════════════════════════════")

let all1054 = blocks.filter { $0.contentType == 0x1054 }.sorted { $0.dataOffset < $1.dataOffset }
var sentinelSections: [Block] = []
if all1054.count >= 2 {
    let sc = all1054[1]
    let ss = sc.dataOffset, se = ss + sc.dataSize
    let ir = blocks.filter { $0.contentType == 0x1054 && $0.dataOffset > ss && $0.dataOffset + $0.dataSize <= se }
        .map { ($0.dataOffset, $0.dataOffset + $0.dataSize) }
    sentinelSections = blocks.filter { b in
        b.contentType == 0x1052 && b.dataOffset >= ss && b.dataOffset + b.dataSize <= se &&
        !ir.contains { r in r.0 <= b.dataOffset && b.dataOffset + b.dataSize <= r.1 }
    }.sorted { $0.dataOffset < $1.dataOffset }
}
print("Sentinel sections: \(sentinelSections.count)")

for (ci, cmpd) in cmpdParents.enumerated() {
    let c2523s = childBlocks(of: cmpd, in: blocks).filter { $0.contentType == 0x2523 }.sorted { $0.dataOffset < $1.dataOffset }
    guard c2523s.count > 1 else { continue }

    let firstCounter = c2523s.first.flatMap { m -> Int? in
        guard m.dataSize >= 39 else { return nil }
        return Int(readLE(data, at: m.dataOffset + 37, count: 2))
    }
    let lastCounter = c2523s.last.flatMap { m -> Int? in
        guard m.dataSize >= 39 else { return nil }
        return Int(readLE(data, at: m.dataOffset + 37, count: 2))
    }

    var name = "?"
    if let nb = childBlocks(of: cmpd, in: blocks).first(where: { $0.contentType == 0x2628 }) {
        let nl = Int(u32(data, at: nb.dataOffset))
        if nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count {
            name = String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
        }
    }

    let firstValid = firstCounter != nil && firstCounter! < sentinelSections.count
    let lastValid = lastCounter != nil && lastCounter! < sentinelSections.count

    print("  [\(ci)] '\(name)' first=\(firstCounter ?? -1)\(firstValid ? "✓" : "✗") last=\(lastCounter ?? -1)\(lastValid ? "✓" : "✗")")
}

// ── D. Check if LOWEST counter per compound matches sentinel ordinal ──
print("\n══════════════════════════════════════════")
print("D. MINIMUM COUNTER PER COMPOUND (original creation?)")
print("══════════════════════════════════════════")
print("If re-creation adds NEW 0x2523 blocks, the FIRST/MIN counter might be original sentinel ordinal")

for ci in targets {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let c2523s = childBlocks(of: cmpd, in: blocks).filter { $0.contentType == 0x2523 }

    let counters = c2523s.compactMap { m -> Int? in
        guard m.dataSize >= 39 else { return nil }
        return Int(readLE(data, at: m.dataOffset + 37, count: 2))
    }

    var name = "?"
    if let nb = childBlocks(of: cmpd, in: blocks).first(where: { $0.contentType == 0x2628 }) {
        let nl = Int(u32(data, at: nb.dataOffset))
        if nl > 0, nl < 512, nb.dataOffset + 4 + nl <= data.count {
            name = String(bytes: data[nb.dataOffset+4..<nb.dataOffset+4+nl], encoding: .utf8) ?? "?"
        }
    }

    let minCounter = counters.min()
    let maxCounter = counters.max()
    let inRange = minCounter != nil && minCounter! < sentinelSections.count
    print("  [\(ci)] '\(name)' counters=\(counters) min=\(minCounter ?? -1)\(inRange ? "✓" : "") max=\(maxCounter ?? -1)")
}

// ── E. Scan ALL 0x2523 bytes for field that equals known sentinel ordinals ──
print("\n══════════════════════════════════════════")
print("E. BRUTE-FORCE: Any byte offset in 0x2523 that matches known sentinels?")
print("══════════════════════════════════════════")
print("compound[479] should→82, compound[480]→83, compound[79]→84, compound[80]→85")

let knownMap: [(ci: Int, sent: Int)] = [(479, 82), (480, 83), (79, 84), (80, 85)]
var matchingOffsets: [Int: Int] = [:]  // byte offset → match count

for (ci, sent) in knownMap {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    let c2523s = childBlocks(of: cmpd, in: blocks).filter { $0.contentType == 0x2523 }

    for m in c2523s {
        // Check every u16 LE position
        for off in 0..<(m.dataSize - 1) {
            let v = Int(u16(data, at: m.dataOffset + off))
            if v == sent {
                matchingOffsets[off, default: 0] += 1
            }
        }
        // Check every u32 LE position
        for off in 0..<(m.dataSize - 3) {
            let v = Int(u32(data, at: m.dataOffset + off))
            if v == sent {
                matchingOffsets[1000 + off, default: 0] += 1  // prefix 1000 to distinguish u32
            }
        }
    }
}

print("Byte offsets where u16/u32 matched known sentinel ordinals:")
for (off, count) in matchingOffsets.sorted(by: { $0.value > $1.value }) {
    let prefix = off >= 1000 ? "u32" : "u16"
    let realOff = off >= 1000 ? off - 1000 : off
    print("  \(prefix)@[\(realOff)]: matched \(count)/4 targets")

    // Show what values the other compounds have at this offset
    if count >= 2 {
        for (ci2, sent2) in knownMap {
            guard ci2 < cmpdParents.count else { continue }
            let c2523s = childBlocks(of: cmpdParents[ci2], in: blocks).filter { $0.contentType == 0x2523 }
            for (j, m) in c2523s.enumerated() {
                let v: Int
                if off >= 1000 {
                    v = Int(u32(data, at: m.dataOffset + realOff))
                } else {
                    v = Int(u16(data, at: m.dataOffset + realOff))
                }
                print("    compound[\(ci2)] 0x2523[\(j)] → \(v) (want \(sent2))")
            }
        }
    }
}

// ── F. Also brute-force the 0x2628 (name+metadata) block ──
print("\n══════════════════════════════════════════")
print("F. BRUTE-FORCE 0x2628: Any byte offset matching known sentinels?")
print("══════════════════════════════════════════")

var matchingOffsets2628: [Int: Int] = [:]
for (ci, sent) in knownMap {
    guard ci < cmpdParents.count else { continue }
    let children = childBlocks(of: cmpdParents[ci], in: blocks)
    guard let nb = children.first(where: { $0.contentType == 0x2628 }) else { continue }

    for off in 0..<(nb.dataSize - 1) {
        let v = Int(u16(data, at: nb.dataOffset + off))
        if v == sent { matchingOffsets2628[off, default: 0] += 1 }
    }
    for off in 0..<(nb.dataSize - 3) {
        let v = Int(u32(data, at: nb.dataOffset + off))
        if v == sent { matchingOffsets2628[1000 + off, default: 0] += 1 }
    }
}

for (off, count) in matchingOffsets2628.sorted(by: { $0.value > $1.value }) where count >= 2 {
    let prefix = off >= 1000 ? "u32" : "u16"
    let realOff = off >= 1000 ? off - 1000 : off
    print("  \(prefix)@[\(realOff)]: matched \(count)/4 targets")
    for (ci2, sent2) in knownMap {
        guard ci2 < cmpdParents.count else { continue }
        let children = childBlocks(of: cmpdParents[ci2], in: blocks)
        guard let nb = children.first(where: { $0.contentType == 0x2628 }) else { continue }
        let v: Int
        if off >= 1000 { v = Int(u32(data, at: nb.dataOffset + realOff)) }
        else { v = Int(u16(data, at: nb.dataOffset + realOff)) }
        print("    compound[\(ci2)] → \(v) (want \(sent2))")
    }
}

// ── G. Brute-force the ENTIRE compound block (0x262b) ──
print("\n══════════════════════════════════════════")
print("G. BRUTE-FORCE ENTIRE 0x262b: Any byte offset matching known sentinels?")
print("══════════════════════════════════════════")

var matchingOffsetsAll: [Int: Int] = [:]
for (ci, sent) in knownMap {
    guard ci < cmpdParents.count else { continue }
    let cmpd = cmpdParents[ci]
    for off in 0..<(cmpd.dataSize - 1) {
        let v = Int(u16(data, at: cmpd.dataOffset + off))
        if v == sent { matchingOffsetsAll[off, default: 0] += 1 }
    }
}

let goodMatches = matchingOffsetsAll.filter { $0.value >= 3 }.sorted { $0.value > $1.value }
print("Offsets matching 3+ of 4 targets:")
for (off, count) in goodMatches {
    print("  u16@[\(off)]: matched \(count)/4")
    for (ci2, sent2) in knownMap {
        guard ci2 < cmpdParents.count else { continue }
        let cmpd = cmpdParents[ci2]
        let v = Int(u16(data, at: cmpd.dataOffset + off))
        print("    compound[\(ci2)] → \(v) (want \(sent2)) \(v == sent2 ? "✓" : "✗")")
    }
}
if goodMatches.isEmpty { print("  (none)") }

print("\nDone.")
