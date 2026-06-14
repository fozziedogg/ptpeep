#!/usr/bin/env swift
// dump_sends.swift
// Find "712SYM mx" in the decoded PTX and show surrounding block structure.
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/honey_bunch_score_mix_PEEPTEST.ptx"
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

func u32le(_ i: Int) -> UInt32 {
    guard i+4 <= data.count else { return 0 }
    return UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
}

struct Block { var ct: UInt16; var off: Int; var size: Int }
func scanBlocks() -> [Block] {
    var blocks = [Block](); var i = 0x1f
    while i + 9 <= data.count {
        guard data[i] == 0x5a else { i += 1; continue }
        let sz = Int(u32le(i+3)); let ct = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
        guard sz > 0, sz < 50_000_000, i + 9 + sz <= data.count else { i += 1; continue }
        blocks.append(Block(ct: ct, off: i+9, size: sz)); i += 1
    }
    return blocks
}

func hexRow(_ from: Int, _ count: Int, base: Int) -> String {
    let end = min(from + count, data.count)
    let hex = (from..<end).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
    let asc = (from..<end).map { b -> String in let c = data[b]; return (c >= 32 && c < 127) ? String(UnicodeScalar(c)) : "." }.joined()
    return String(format: "  +%04d (0x%06x): ", from - base, from) + hex + "  " + asc
}

let blocks = scanBlocks()

// ── 1. Find all occurrences of the send bus name ──────────────────────────────
let target = "712SYM mx"
let tBytes = Array(target.utf8)
var hits = [Int]()
for i in 0...(data.count - tBytes.count) {
    if data[i..<(i + tBytes.count)].elementsEqual(tBytes) { hits.append(i) }
}
print("Found \"\(target)\" at \(hits.count) location(s): \(hits.map { String(format: "0x%x", $0) }.joined(separator: ", "))")

for hit in hits {
    print("\n── Hit at 0x\(String(format: "%x", hit)) ──")
    // Show 60 bytes before the string
    let ctxStart = max(0, hit - 60)
    print("Context (-60 bytes):")
    var p = ctxStart
    while p < hit + tBytes.count + 20 {
        print(hexRow(p, 16, base: ctxStart))
        p += 16
    }

    // Find enclosing blocks (largest first, then by proximity)
    let enclosing = blocks.filter { $0.off <= hit && $0.off + $0.size >= hit + tBytes.count }
        .sorted { $0.size < $1.size }  // smallest enclosing first
    print("\nEnclosing blocks (smallest first):")
    for b in enclosing.prefix(6) {
        print(String(format: "  0x%04x @0x%x..0x%x (sz=%d, relOff=%d)",
                     b.ct, b.off, b.off + b.size, b.size, hit - b.off))
    }

    // Find nearest 0x5a block header before the hit
    print("\nNearest block headers before hit:")
    var found = 0
    var back = hit - 9
    while back >= max(0, hit - 200) && found < 5 {
        if data[back] == 0x5a {
            let sz = Int(u32le(back+3)); let ct = UInt16(data[back+7]) | UInt16(data[back+8]) << 8
            if sz > 0 && sz < 50_000_000 && back + 9 + sz <= data.count {
                print(String(format: "  0x%04x @0x%x sz=%d (hit is at rel+%d)",
                             ct, back+9, sz, hit - (back+9)))
                found += 1
            }
        }
        back -= 1
    }
}

// ── 2. For one track we know has a send, dump ALL LP strings in its container ──
// Find 0x261b containers and show all LP-prefixed strings inside them
print("\n\n── All LP strings in first 5 x 0x261b containers ──")
let containers = blocks.filter { $0.ct == 0x261b }.sorted { $0.off < $1.off }
for container in containers.prefix(5) {
    let cEnd = container.off + container.size
    var strings = [(rel: Int, s: String)]()
    var pos = container.off
    while pos + 4 < cEnd {
        let len = Int(u32le(pos))
        if len >= 2 && len <= 256 && pos + 4 + len <= cEnd {
            if let s = String(bytes: data[(pos+4)..<(pos+4+len)], encoding: .utf8),
               s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xd800 }),
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                strings.append((rel: pos - container.off, s: s))
            }
        }
        pos += 1
    }
    // Only show containers that have send-like strings
    let unique = Array(Set(strings.map { $0.s })).sorted()
    if unique.contains(where: { $0.contains("712") || $0.contains("SYM") || $0.contains("Send") }) {
        print("\n0x261b @\(container.off) sz=\(container.size)")
        for (rel, s) in strings { print("  +\(rel): \"\(s)\"") }
    }
}
