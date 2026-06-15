#!/usr/bin/env swift
// sentinel_diagnostic.swift — Dump unexplored binary fields for sentinel mapping research
// Usage: swift sentinel_diagnostic.swift <file.ptx>

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

func xorDecode(_ raw: Data) -> Data? {
    guard raw.count > 0x14 else { return nil }
    let fileType = raw[0x12]
    let xorValue = raw[0x13]
    let mul: UInt16
    let negative: Bool
    switch fileType {
    case 0x05: mul = 11; negative = true
    case 0x01: mul = 53; negative = false
    default: return nil
    }
    var delta: UInt8 = 0
    for i: UInt16 in 0...255 {
        if (i * mul) & 0xff == UInt16(xorValue) {
            delta = negative ? UInt8(truncatingIfNeeded: 256 &- Int(i)) : UInt8(i)
            break
        }
    }
    var table = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var decoded = raw
    if fileType == 0x05 {
        let chunkSize = 4096
        for chunk in stride(from: chunkSize, to: raw.count, by: chunkSize) {
            let xorByte = table[(chunk >> 12) & 0xff]
            guard xorByte != 0 else { continue }
            let end = min(chunk + chunkSize, raw.count)
            for i in chunk..<end { decoded[i] = raw[i] ^ xorByte }
        }
    } else {
        for i in 0..<raw.count { decoded[i] = raw[i] ^ table[i & 0xff] }
    }
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
    let pStart = parent.dataOffset
    let pEnd = pStart + parent.dataSize
    return blocks.filter { $0.dataOffset >= pStart && $0.dataOffset + $0.dataSize <= pEnd && $0.dataOffset != parent.dataOffset }
}

func hexDump(_ d: Data, at offset: Int, count: Int) -> String {
    let end = min(offset + count, d.count)
    guard offset < end else { return "(empty)" }
    return (offset..<end).map { String(format: "%02x", d[$0]) }.joined(separator: " ")
}

// MARK: - Main

guard CommandLine.arguments.count > 1 else {
    print("Usage: swift sentinel_diagnostic.swift <file.ptx>")
    exit(1)
}
let path = CommandLine.arguments[1]
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    print("Cannot read \(path)")
    exit(1)
}
guard let data = xorDecode(raw) else {
    print("XOR decode failed")
    exit(1)
}
let blocks = scanBlocks(data)
print("Blocks: \(blocks.count)")

let audioParents = blocks.filter { $0.contentType == 0x2629 }.sorted { $0.dataOffset < $1.dataOffset }
let cmpdParents = blocks.filter { $0.contentType == 0x262b }.sorted { $0.dataOffset < $1.dataOffset }
print("Audio pool (0x2629): \(audioParents.count)")
print("Compound pool (0x262b): \(cmpdParents.count)")

// ── 1. Compound child block types ──
print("\n══════════════════════════════════════════")
print("1. CHILD BLOCK TYPES INSIDE EACH 0x262b COMPOUND")
print("══════════════════════════════════════════")

// Collect unique child types across all compounds
var childTypeCounts: [UInt16: Int] = [:]
for (ci, cmpd) in cmpdParents.enumerated() {
    let children = childBlocks(of: cmpd, in: blocks)
    for ch in children {
        childTypeCounts[ch.contentType, default: 0] += 1
    }
}
print("\nChild block type summary across all \(cmpdParents.count) compounds:")
for (ct, count) in childTypeCounts.sorted(by: { $0.key < $1.key }) {
    print("  0x\(String(format: "%04x", ct)): \(count) occurrences")
}

// Detailed dump for first 5 compounds + known ones (479, 480, 79, 80)
let interestingCIs = Set([0, 1, 2, 3, 4, 79, 80, 479, 480])
for (ci, cmpd) in cmpdParents.enumerated() {
    guard interestingCIs.contains(ci) || ci < 5 else { continue }
    guard ci < cmpdParents.count else { continue }
    let children = childBlocks(of: cmpd, in: blocks)
    // Get name from 0x2628 child
    var name = "?"
    if let nameBlock = children.first(where: { $0.contentType == 0x2628 }) {
        let nl = Int(u32(data, at: nameBlock.dataOffset))
        if nl > 0, nl < 512, nameBlock.dataOffset + 4 + nl <= data.count {
            name = String(bytes: data[nameBlock.dataOffset+4..<nameBlock.dataOffset+4+nl], encoding: .utf8) ?? "?"
        }
    }
    let types = children.map { "0x\(String(format: "%04x", $0.contentType))" }
    print("\n  compound[\(ci)] '\(name)' — \(children.count) children: \(types.joined(separator: ", "))")

    // If any 0x104f children, dump them
    let child104fs = children.filter { $0.contentType == 0x104f }
    if !child104fs.isEmpty {
        print("    *** HAS 0x104f CHILDREN! ***")
        for (j, c104f) in child104fs.enumerated() {
            print("    0x104f[\(j)]: size=\(c104f.dataSize) bytes: \(hexDump(data, at: c104f.dataOffset, count: min(c104f.dataSize, 40)))")
            if c104f.dataSize >= 19 {
                let ci2 = Int(u16(data, at: c104f.dataOffset + 2))
                let tl = readLE(data, at: c104f.dataOffset + 7, count: 8)
                let b18 = data[c104f.dataOffset + 18]
                print("      ci=\(ci2), tl=\(tl), b18=0x\(String(format: "%02x", b18))")
            }
        }
    }

    // Dump all non-standard children (anything except 0x2628, 0x2523, 0x2526)
    let unusual = children.filter { $0.contentType != 0x2628 && $0.contentType != 0x2523 && $0.contentType != 0x2526 }
    for ch in unusual {
        print("    unusual child 0x\(String(format: "%04x", ch.contentType)): size=\(ch.dataSize) bytes: \(hexDump(data, at: ch.dataOffset, count: min(ch.dataSize, 40)))")
    }
}

// ── 2. Sentinel 0x1052 section headers ──
print("\n══════════════════════════════════════════")
print("2. SENTINEL 0x1052 SECTION HEADERS")
print("══════════════════════════════════════════")

let all1054 = blocks.filter { $0.contentType == 0x1054 }.sorted { $0.dataOffset < $1.dataOffset }
guard all1054.count >= 2 else {
    print("No sentinel container found (need ≥2 0x1054 blocks)")
    exit(0)
}
let sentContainer = all1054[1]
let sStart = sentContainer.dataOffset, sEnd = sStart + sentContainer.dataSize
let innerRanges = blocks.filter {
    $0.contentType == 0x1054 && $0.dataOffset > sStart && $0.dataOffset + $0.dataSize <= sEnd
}.map { ($0.dataOffset, $0.dataOffset + $0.dataSize) }
let sentinelSections = blocks.filter { blk in
    blk.contentType == 0x1052 &&
    blk.dataOffset >= sStart && blk.dataOffset + blk.dataSize <= sEnd &&
    !innerRanges.contains { r in r.0 <= blk.dataOffset && blk.dataOffset + blk.dataSize <= r.1 }
}.sorted { $0.dataOffset < $1.dataOffset }

print("Sentinel sections: \(sentinelSections.count)")

// Dump headers for interesting sentinels (82-85 are the known-correct ones for PeepTestD)
let interestingSents = Set(Array(0..<5) + Array(70..<90) + [164, 165, 166, 167, 222])
for (idx, sect) in sentinelSections.enumerated() {
    guard interestingSents.contains(idx) else { continue }
    // Section header = raw bytes at start of section content before first child block
    let firstChild = blocks.filter {
        $0.dataOffset > sect.dataOffset && $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize
    }.sorted { $0.dataOffset < $1.dataOffset }.first
    let headerEnd = firstChild.map { $0.dataOffset - 9 } ?? (sect.dataOffset + min(sect.dataSize, 40))  // -9 for 5a header
    let headerLen = headerEnd - sect.dataOffset

    // Count 0x104f children and extract their ci values
    let SENT_ORIGIN: UInt64 = 1_000_000_000_000
    let plBlocks = blocks.filter {
        $0.contentType == 0x104f &&
        $0.dataOffset >= sect.dataOffset && $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize
    }
    var ciSet: [Int] = []
    var hasCompound = false
    for pl in plBlocks {
        guard pl.dataSize >= 19 else { continue }
        let tl = readLE(data, at: pl.dataOffset + 7, count: 8)
        guard tl >= SENT_ORIGIN else { continue }
        let ci2 = Int(u16(data, at: pl.dataOffset + 2))
        let b18 = data[pl.dataOffset + 18]
        ciSet.append(ci2)
        if b18 == 0x01 { hasCompound = true }
    }

    let tag = hasCompound ? " [HAS COMPOUND REFS]" : ""
    print("  sentinel[\(idx)]: headerLen=\(headerLen), \(plBlocks.count) placements, ci=\(ciSet)\(tag)")
    print("    header: \(hexDump(data, at: sect.dataOffset, count: min(headerLen, 40)))")

    // Also dump the raw first 20 bytes unconditionally
    print("    raw20:  \(hexDump(data, at: sect.dataOffset, count: min(20, sect.dataSize)))")
}

// ── 3. Active b18=0x01 compound placements — ALL bytes ──
print("\n══════════════════════════════════════════")
print("3. ACTIVE b18=0x01 COMPOUND PLACEMENTS — FULL BYTE DUMP")
print("══════════════════════════════════════════")

let activeContainer = all1054[0]
let acStart = activeContainer.dataOffset, acEnd = acStart + activeContainer.dataSize
let activeSections = blocks.filter { blk in
    blk.contentType == 0x1052 &&
    blk.dataOffset >= acStart && blk.dataOffset + blk.dataSize <= acEnd
}.sorted { $0.dataOffset < $1.dataOffset }

print("Active sections: \(activeSections.count)")

for (secIdx, sect) in activeSections.enumerated() {
    let secEnd = sect.dataOffset + sect.dataSize
    let refs = blocks.filter {
        $0.contentType == 0x104f &&
        $0.dataOffset >= sect.dataOffset && $0.dataOffset + $0.dataSize <= secEnd
    }.sorted { $0.dataOffset < $1.dataOffset }

    for ref in refs {
        guard ref.dataSize >= 19 else { continue }
        let b18 = data[ref.dataOffset + 18]
        guard b18 == 0x01 else { continue }  // only compound placements
        let clipIdx = Int(u16(data, at: ref.dataOffset + 2))
        let tl = readLE(data, at: ref.dataOffset + 7, count: 8)
        guard tl < 1_000_000_000_000 else { continue }

        // Get compound name
        var name = "?"
        if clipIdx < cmpdParents.count {
            let children = childBlocks(of: cmpdParents[clipIdx], in: blocks)
            if let nameBlock = children.first(where: { $0.contentType == 0x2628 }) {
                let nl = Int(u32(data, at: nameBlock.dataOffset))
                if nl > 0, nl < 512, nameBlock.dataOffset + 4 + nl <= data.count {
                    name = String(bytes: data[nameBlock.dataOffset+4..<nameBlock.dataOffset+4+nl], encoding: .utf8) ?? "?"
                }
            }
        }

        // Current sentinel lookup
        var counter = clipIdx
        if clipIdx < cmpdParents.count {
            let cmpd = cmpdParents[clipIdx]
            for m in blocks where m.contentType == 0x2523
                && m.dataOffset >= cmpd.dataOffset
                && m.dataOffset + m.dataSize <= cmpd.dataOffset + cmpd.dataSize
                && m.dataSize >= 39 {
                counter = Int(readLE(data, at: m.dataOffset + 37, count: 2))
                break
            }
        }

        print("\n  activeSection[\(secIdx)] ci=\(clipIdx) '\(name)' tl=\(tl) counter=\(counter)")
        print("    ALL \(ref.dataSize) bytes: \(hexDump(data, at: ref.dataOffset, count: ref.dataSize))")

        // Annotated byte breakdown
        if ref.dataSize >= 36 {
            print("    byte[0]=\(String(format: "0x%02x", data[ref.dataOffset]))")
            print("    byte[1]=\(String(format: "0x%02x", data[ref.dataOffset+1]))")
            print("    byte[2..3] ci=\(u16(data, at: ref.dataOffset+2)) (0x\(String(format: "%04x", u16(data, at: ref.dataOffset+2))))")
            print("    byte[4..6]=\(hexDump(data, at: ref.dataOffset+4, count: 3))")
            print("    byte[7..14] tl=\(readLE(data, at: ref.dataOffset+7, count: 8))")
            print("    byte[15..17]=\(hexDump(data, at: ref.dataOffset+15, count: 3))")
            print("    byte[18] b18=\(String(format: "0x%02x", data[ref.dataOffset+18]))")
            print("    byte[19..22]=\(hexDump(data, at: ref.dataOffset+19, count: 4)) u32=\(u32(data, at: ref.dataOffset+19))")
            print("    byte[23..26]=\(hexDump(data, at: ref.dataOffset+23, count: 4)) u32=\(u32(data, at: ref.dataOffset+23))")
            print("    byte[27..30]=\(hexDump(data, at: ref.dataOffset+27, count: 4)) u32=\(u32(data, at: ref.dataOffset+27))")
            print("    byte[31..32]=\(hexDump(data, at: ref.dataOffset+31, count: 2)) u16=\(u16(data, at: ref.dataOffset+31))")
            print("    byte[33..34]=\(hexDump(data, at: ref.dataOffset+33, count: 2)) u16=\(u16(data, at: ref.dataOffset+33))")
            print("    byte[35]=\(String(format: "0x%02x", data[ref.dataOffset+35]))")
            if ref.dataSize > 36 {
                print("    byte[36..]=\(hexDump(data, at: ref.dataOffset+36, count: min(ref.dataSize-36, 20)))")
            }
        }
    }
}

// ── 4. Content-match validation ──
print("\n══════════════════════════════════════════")
print("4. CONTENT-MATCH: SENTINEL CI SETS vs COMPOUND LENGTHS")
print("══════════════════════════════════════════")

// For each sentinel, compute: ci set, total span, min/max relative offset
let SENT_ORIGIN: UInt64 = 1_000_000_000_000
for (idx, sect) in sentinelSections.enumerated() {
    let plBlocks = blocks.filter {
        $0.contentType == 0x104f &&
        $0.dataOffset >= sect.dataOffset && $0.dataOffset + $0.dataSize <= sect.dataOffset + sect.dataSize
    }
    var ciVals: [Int] = []
    var minOff: UInt64 = UInt64.max
    var maxOff: UInt64 = 0
    for pl in plBlocks {
        guard pl.dataSize >= 19 else { continue }
        let tl = readLE(data, at: pl.dataOffset + 7, count: 8)
        guard tl >= SENT_ORIGIN else { continue }
        let relOff = tl - SENT_ORIGIN
        ciVals.append(Int(u16(data, at: pl.dataOffset + 2)))
        if relOff < minOff { minOff = relOff }
        if relOff > maxOff { maxOff = relOff }
    }
    guard !ciVals.isEmpty else { continue }
    // Only print sentinel sections near interesting ordinals
    guard interestingSents.contains(idx) else { continue }
    print("  sentinel[\(idx)]: ciVals=\(ciVals.sorted()), minOff=\(minOff), maxOff=\(maxOff), span=\(maxOff-minOff)")
}

// Print compound lengths for comparison
print("\nCompound lengths:")
for ci in [0, 1, 2, 3, 4, 79, 80, 479, 480] {
    guard ci < cmpdParents.count else { continue }
    let children = childBlocks(of: cmpdParents[ci], in: blocks)
    if let nameBlock = children.first(where: { $0.contentType == 0x2628 }) {
        let nl = Int(u32(data, at: nameBlock.dataOffset))
        if nl > 0, nl < 512, nameBlock.dataOffset + 4 + nl <= data.count {
            let name = String(bytes: data[nameBlock.dataOffset+4..<nameBlock.dataOffset+4+nl], encoding: .utf8) ?? "?"
            let tp = nameBlock.dataOffset + 4 + nl
            if tp + 5 <= data.count {
                let nLength = Int((data[tp + 2] & 0xf0) >> 4)
                let nSrcOff = Int((data[tp + 1] & 0xf0) >> 4)
                var vp = tp + 5 + nSrcOff
                let lengthVal = readLE(data, at: vp, count: nLength)
                print("  compound[\(ci)] '\(name)' length=\(lengthVal)")
            }
        }
    }
}

print("\nDone.")
