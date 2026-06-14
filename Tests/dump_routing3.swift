#!/usr/bin/env swift
// dump_routing3.swift
// Maps 0x261b routing blocks to tracks via 0x102d strips.
// Decodes 0x260d sub-blocks (each = one path: input, output, or send)
// and reads the 0x260e LP string inside each.
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

struct Block { var ct: UInt16; var off: Int; var size: Int }
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
        blocks.append(Block(ct: ct, off: i + 9, size: size))
        i += 1
    }
    return blocks
}

let blocks = scanBlocks(data)

// LP string reader
func lpStr(_ off: Int, limit: Int) -> (String, Int)? {
    guard off + 4 <= limit else { return nil }
    let len = Int(u32le(data, off))
    guard len > 0, len <= 512, off + 4 + len <= limit else { return nil }
    guard let s = String(bytes: data[(off+4)..<(off+4+len)], encoding: .utf8) else { return nil }
    return (s, off + 4 + len)
}

// ── Track name from 0x102d ─────────────────────────────────────────────────
// 0x102d data starts with a 0x5a sub-block header (9 bytes), then LP string
func trackNameFrom102d(_ b: Block) -> String {
    let p = b.off
    // inner block header: 5a XX XX size(4) ct(2) → 9 bytes
    guard b.size > 9, data[p] == 0x5a else {
        // Try direct LP string
        if let (name, _) = lpStr(p, limit: b.off + b.size) { return name }
        return "?"
    }
    if let (name, _) = lpStr(p + 9, limit: b.off + b.size) { return name }
    return "?"
}

// ── Dump 0x260d blocks (path entries) within a 0x261b block ───────────────
// 0x260d layout:
//   byte[0]: path role? (we'll display it)
//   then possibly more bytes before 0x260e sub-block
// 0x260e layout: LP string (4-byte len + chars)

func dumpPaths(in b261b: Block) -> [(role: UInt8, name: String)] {
    var results: [(UInt8, String)] = []
    let end = b261b.off + b261b.size

    // Find all 0x260d sub-blocks inside b261b
    var pos = b261b.off
    while pos + 9 < end {
        guard data[pos] == 0x5a else { pos += 1; continue }
        let sz  = Int(u32le(data, pos+3))
        let ct  = UInt16(data[pos+7]) | UInt16(data[pos+8]) << 8
        guard sz > 0, sz < 50_000_000, pos + 9 + sz <= end else { pos += 1; continue }
        if ct == 0x260d {
            let dOff = pos + 9       // data start of 0x260d
            let dEnd = dOff + sz
            let role = dOff < dEnd ? data[dOff] : 0xff

            // Find 0x260e inside 0x260d
            var inner = dOff
            while inner + 9 < dEnd {
                guard data[inner] == 0x5a else { inner += 1; continue }
                let isz = Int(u32le(data, inner+3))
                let ict = UInt16(data[inner+7]) | UInt16(data[inner+8]) << 8
                guard isz > 0, inner + 9 + isz <= dEnd else { inner += 1; continue }
                if ict == 0x260e {
                    if let (name, _) = lpStr(inner + 9, limit: inner + 9 + isz) {
                        results.append((role, name))
                    }
                }
                inner += 1
            }
            // Also check for LP string directly in 0x260d if no 0x260e found
            if !results.contains(where: { _ in true }) || results.last?.0 != role {
                if let (name, _) = lpStr(dOff + 1, limit: dEnd) {
                    // might be direct
                }
            }
        }
        pos += 1
    }
    return results
}

// ── Ordered strips and 0x261b blocks ──────────────────────────────────────
let strips  = blocks.filter { $0.ct == 0x102d }.sorted { $0.off < $1.off }
let routing = blocks.filter { $0.ct == 0x261b }.sorted { $0.off < $1.off }

print("0x102d strips: \(strips.count)")
print("0x261b blocks: \(routing.count)\n")

// For each strip, find the nearest 0x261b that follows it (before the next strip)
print(String(repeating: "-", count: 90))

for (i, strip) in strips.enumerated() {
    let name = trackNameFrom102d(strip)
    let nextStripOff = i + 1 < strips.count ? strips[i+1].off : data.count

    // Find 0x261b blocks between this strip and the next
    let nearby261b = routing.filter { $0.off >= strip.off && $0.off < nextStripOff }

    if nearby261b.isEmpty {
        print("Track: \"\(name)\" — no 0x261b nearby")
        continue
    }

    for r in nearby261b {
        let paths = dumpPaths(in: r)
        print("Track: \"\(name)\" — 0x261b @0x\(String(r.off, radix:16)) sz=\(r.size)")
        for p in paths { print("  role=0x\(String(format:"%02x", p.role)) name=\"\(p.name)\"") }
        if paths.isEmpty { print("  (no paths found)") }
    }
}

// ── Also dump raw bytes of first few 0x260d blocks ───────────────────────
print("\n── First 5 x 0x260d block raw bytes (for role byte analysis) ──\n")
let d260 = blocks.filter { $0.ct == 0x260d }.sorted { $0.off < $1.off }.prefix(5)
for b in d260 {
    let end = min(b.off + b.size, b.off + 32)
    let hex = (b.off..<end).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
    let asc = (b.off..<end).map { data[$0] >= 32 && data[$0] < 127 ? String(UnicodeScalar(data[$0])) : "." }.joined()
    print("0x260d @0x\(String(b.off, radix:16)) sz=\(b.size)")
    print("  hex: \(hex)")
    print("  asc: \(asc)")
    print()
}
