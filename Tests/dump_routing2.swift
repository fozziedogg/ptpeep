#!/usr/bin/env swift
// dump_routing2.swift
// Finds which block type contains the routing strings, and maps them to tracks.
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/PeepTest.ptx"
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("Cannot read \(path)"); exit(1) }

func xorDecode(_ raw: Data) -> Data? {
    guard raw.count > 0x14, raw[0x12] == 0x05 else { return nil }
    let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
    for i: UInt16 in 0...255 { if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break } }
    var t = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var d = raw; for i in 0..<raw.count { d[i] = raw[i] ^ t[(i >> 12) & 0xff] }
    return d
}

guard let data = xorDecode(raw) else { print("XOR decode failed"); exit(1) }

struct Block { var ct: UInt16; var off: Int; var size: Int; var headerOff: Int }
func u32le(_ d: Data, _ i: Int) -> UInt32 {
    guard i+4 <= d.count else { return 0 }
    return UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
}
func scanBlocks(_ data: Data) -> [Block] {
    var blocks = [Block](); var i = 0x1f
    while i + 9 <= data.count {
        guard data[i] == 0x5a else { i += 1; continue }
        let size = Int(u32le(data, i+3))
        let ct   = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
        guard size > 0, size < 50_000_000, i + 9 + size <= data.count else { i += 1; continue }
        blocks.append(Block(ct: ct, off: i + 9, size: size, headerOff: i))
        i += 1
    }
    return blocks
}

let blocks = scanBlocks(data)

// Known routing strings from the session
let routingStrings = [
    "LoRo.Stereo", "STERO OUT", "FULL MIX", "OUT 1-2",
]

// Find all offsets where routing strings appear
var routingHits: [(String, Int)] = []
for s in routingStrings {
    guard let needle = s.data(using: .utf8) else { continue }
    var pos = 0
    while pos + needle.count <= data.count {
        if data[pos..<(pos + needle.count)] == needle { routingHits.append((s, pos)) }
        pos += 1
    }
}

print("── For each routing string, which block type contains it? ──\n")
for (s, hitOff) in routingHits.sorted(by: { $0.1 < $1.1 }) {
    // Find the innermost block containing this offset
    let containing = blocks.filter { $0.off <= hitOff && hitOff < $0.off + $0.size }
        .sorted { ($0.size) < ($1.size) }  // smallest (innermost) first
    let inner = containing.prefix(3).map { String(format: "0x%04x(sz=\($0.size))", $0.ct) }.joined(separator: " ⊂ ")
    print("  \"\(s)\" @0x\(String(hitOff, radix:16)): \(inner)")
}

// ── Now focus on the innermost block type and dump its full content ──────

print("\n── Dump blocks that contain routing strings (innermost block) ──\n")

// Collect unique innermost block types containing routing strings
var innerTypes = Set<UInt16>()
for (_, hitOff) in routingHits {
    if let inner = blocks.filter({ $0.off <= hitOff && hitOff < $0.off + $0.size })
        .sorted(by: { $0.size < $1.size }).first {
        innerTypes.insert(inner.ct)
    }
}
print("Innermost block types: \(innerTypes.map { String(format: "0x%04x", $0) })\n")

// For each 0x102d block, find the blocks that follow it (same file region)
// and dump all LP strings in those blocks
let strips = blocks.filter { $0.ct == 0x102d }

for b in strips {
    let end = b.off + b.size
    // Track name from LP string at b.off
    let nl = Int(u32le(data, b.off))
    let trackName = nl > 0 && nl <= 256 && b.off + 4 + nl <= end
        ? (String(bytes: data[(b.off+4)..<(b.off+4+nl)], encoding: .utf8) ?? "?") : "?"

    // Find all blocks in the next 8KB that are NOT 0x102d and contain routing strings
    let searchEnd = min(data.count, end + 8192)
    let nearBlocks = blocks.filter {
        $0.off >= end && $0.off < searchEnd && $0.ct != 0x102d
    }.sorted { $0.off < $1.off }

    print("Track: \"\(trackName)\" (strip @0x\(String(b.off, radix:16)))")
    for nb in nearBlocks.prefix(20) {
        let nbEnd = nb.off + nb.size
        // Collect all LP strings in this block
        var strings: [String] = []
        var pos = nb.off
        while pos + 4 < nbEnd {
            let len = Int(u32le(data, pos))
            if len >= 2 && len <= 64 && pos + 4 + len <= nbEnd {
                if let s = String(bytes: data[(pos+4)..<(pos+4+len)], encoding: .utf8),
                   s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) {
                    strings.append(s)
                }
            }
            pos += 1
        }
        if !strings.isEmpty {
            print("  block 0x\(String(format:"%04x", nb.ct)) @0x\(String(nb.off, radix:16)) sz=\(nb.size): \(strings)")
        }
    }
    print()
}
