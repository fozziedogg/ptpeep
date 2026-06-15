#!/usr/bin/env swift
// dump_routing.swift
// Searches for known routing strings in PeepTest.ptx near 0x102d mixer strip blocks.
// Also does a raw string search to confirm strings are present in decoded binary.
import Foundation

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Tests/PeepTest.ptx"

guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    print("Cannot read \(path)"); exit(1)
}

// XOR decode
func xorDecode(_ raw: Data) -> Data? {
    guard raw.count > 0x14, raw[0x12] == 0x05 else { return nil }
    let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
    for i: UInt16 in 0...255 {
        if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break }
    }
    var t = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var d = raw
    for i in 0..<raw.count { d[i] = raw[i] ^ t[(i >> 12) & 0xff] }
    return d
}

guard let data = xorDecode(raw) else { print("XOR decode failed"); exit(1) }
print("Decoded \(data.count) bytes\n")

// Block scan
struct Block { var ct: UInt16; var off: Int; var size: Int }
func scanBlocks(_ data: Data) -> [Block] {
    var blocks = [Block](); var i = 0x1f
    while i + 9 <= data.count {
        guard data[i] == 0x5a else { i += 1; continue }
        let size = Int(UInt32(data[i+3]) | UInt32(data[i+4]) << 8 | UInt32(data[i+5]) << 16 | UInt32(data[i+6]) << 24)
        let ct   = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
        guard size > 0, size < 50_000_000, i + 9 + size <= data.count else { i += 1; continue }
        blocks.append(Block(ct: ct, off: i + 9, size: size))
        i += 1
    }
    return blocks
}

func u32le(_ d: Data, _ i: Int) -> UInt32 {
    guard i + 4 <= d.count else { return 0 }
    return UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
}

// Read a length-prefixed string (4-byte LE length + bytes)
func lpString(_ d: Data, at off: Int, limit: Int) -> (String, Int)? {
    guard off + 4 <= limit else { return nil }
    let len = Int(u32le(d, off))
    guard len > 0, len <= 512, off + 4 + len <= limit else { return nil }
    guard let s = String(bytes: d[(off+4)..<(off+4+len)], encoding: .utf8) else { return nil }
    return (s, off + 4 + len)
}

let blocks = scanBlocks(data)
print("Total blocks: \(blocks.count)")

// ── 1. Raw string search for known routing values ──────────────────────────

let knownStrings = [
    "LoRo.Stereo", "STERO OUT", "STEREO OUT", "FULL MIX",
    "OUT 1-2", "OUT1-2", "OUT 1", "OUT 2",
]

print("\n── Raw string occurrences in decoded binary ──")
for s in knownStrings {
    guard let needle = s.data(using: .utf8) else { continue }
    var hits: [Int] = []
    var pos = 0
    while pos + needle.count <= data.count {
        if data[pos..<(pos + needle.count)] == needle {
            hits.append(pos)
        }
        pos += 1
    }
    if hits.isEmpty {
        print("  \"\(s)\": NOT FOUND")
    } else {
        print("  \"\(s)\": \(hits.count) hit(s) at \(hits.prefix(8).map { "0x\(String($0, radix:16))" }.joined(separator: ", "))")
    }
}

// ── 2. Dump all 0x102d mixer strip blocks ─────────────────────────────────

let strips = blocks.filter { $0.ct == 0x102d }
print("\n── 0x102d mixer strip blocks: \(strips.count) ──\n")

// Known track names from the session in expected order
let knownTracks = [
    "PIX", "GT PIX", "SVB_BTS_InstagramMix", "Printmaster",
    "Master Bus", "ƒ DME", "SVB_102_2.0 DIA_Final_01",
    "SVB_102_2.0 MUS_Final_01", "SVB_102_2.0 SFX_Final_01",
    "vDME", "Haley 1", "Haley 2", "Haley 1.dup1", "PART ONE.dup1", "Aux 1",
]

for (idx, b) in strips.enumerated() {
    let p    = b.off
    let end  = b.off + b.size
    print("Strip #\(idx)  @0x\(String(p, radix:16))  size=\(b.size)")

    // Dump first 128 bytes as hex + ASCII
    let preview = min(128, b.size)
    var hex   = ""
    var ascii = ""
    for k in 0..<preview {
        let byte = data[p + k]
        hex   += String(format: "%02x ", byte)
        ascii += (byte >= 32 && byte < 127) ? String(UnicodeScalar(byte)) : "."
        if (k+1) % 16 == 0 { hex += " " }
    }
    print("  hex:   \(hex)")
    print("  ascii: \(ascii)")

    // Scan for any of our known routing strings within ±4096 bytes of this block
    let scanStart = max(0, p - 512)
    let scanEnd   = min(data.count, end + 4096)
    var found: [(String, Int)] = []
    for s in knownStrings {
        guard let needle = s.data(using: .utf8) else { continue }
        var pos = scanStart
        while pos + needle.count <= scanEnd {
            if data[pos..<(pos + needle.count)] == needle {
                found.append((s, pos))
            }
            pos += 1
        }
    }
    if !found.isEmpty {
        print("  *** Routing strings nearby:")
        for (s, off) in found.sorted(by: { $0.1 < $1.1 }) {
            let rel = off - p
            print("      \"\(s)\" at 0x\(String(off, radix:16)) (offset \(rel >= 0 ? "+" : "")\(rel) from block start)")
            // Show 16 bytes before the string for context
            let ctx = max(0, off - 16)
            var ctxHex = ""
            for k in ctx..<off { ctxHex += String(format: "%02x ", data[k]) }
            print("        context before: \(ctxHex)")
        }
    }
    print()
}

// ── 3. Dump all LP strings found within each 0x102d block ─────────────────

print("\n── LP strings inside each 0x102d block ──\n")
for (idx, b) in strips.enumerated() {
    let end = b.off + b.size
    print("Strip #\(idx) @0x\(String(b.off, radix:16)):")
    var pos = b.off
    while pos + 4 < end {
        let len = Int(u32le(data, pos))
        if len >= 2 && len <= 128 && pos + 4 + len <= end {
            if let s = String(bytes: data[(pos+4)..<(pos+4+len)], encoding: .utf8),
               s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) {
                print("  +\(pos - b.off): len=\(len) \"\(s)\"")
            }
        }
        pos += 1
    }
    print()
}
