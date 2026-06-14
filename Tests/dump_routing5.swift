#!/usr/bin/env swift
// dump_routing5.swift
// Final: read LP string at offset +36 within 0x260e, map to tracks via 0x261b containers.
// Also scans all offsets 0-48 to find any LP string in 0x260e.
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
func isInside(_ inner: Block, _ outer: Block) -> Bool {
    inner.off >= outer.off && inner.off + inner.size <= outer.off + outer.size
}
func lpStr(at off: Int, limit: Int) -> String? {
    guard off + 4 <= limit else { return nil }
    let len = Int(u32le(data, off))
    guard len > 0, len <= 256, off + 4 + len <= limit else { return nil }
    guard let s = String(bytes: data[(off+4)..<(off+4+len)], encoding: .utf8) else { return nil }
    return s
}
func trackName(_ b: Block) -> String {
    guard b.size > 9, data[b.off] == 0x5a else {
        return lpStr(at: b.off, limit: b.off + b.size) ?? "?"
    }
    return lpStr(at: b.off + 9, limit: b.off + b.size) ?? "?"
}

let blocks = scanBlocks(data)
let allStrips = blocks.filter { $0.ct == 0x102d }
let all261b   = blocks.filter { $0.ct == 0x261b }
let all260e   = blocks.filter { $0.ct == 0x260e }

// ── Scan 0x260e blocks for LP strings at various offsets ─────────────────

print("── 0x260e blocks and their LP strings (scanning offsets 0,4,8,...48) ──\n")
for e in all260e.sorted(by: { $0.off < $1.off }) {
    let limit = e.off + e.size
    var found: [(Int, String)] = []
    for tryOff in stride(from: 0, through: 48, by: 4) {
        if let s = lpStr(at: e.off + tryOff, limit: limit), s.count >= 2 {
            found.append((tryOff, s))
        }
    }
    let hex = (e.off..<min(e.off+24, limit)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
    print("0x260e @0x\(String(e.off, radix:16)) sz=\(e.size): \(found.isEmpty ? "(nothing)" : found.map { "+\($0.0):\"\($0.1)\"" }.joined(separator: " | "))")
    print("  hex: \(hex)")
}

// ── Map tracks to their path strings ─────────────────────────────────────

print("\n── Track routing (0x261b → innermost 0x260e LP strings) ──\n")
for strip in allStrips.sorted(by: { $0.off < $1.off }) {
    let name = trackName(strip)
    // Find smallest 0x261b containing this strip
    let containers = all261b.filter { isInside(strip, $0) }.sorted { $0.size < $1.size }
    guard let container = containers.first else {
        print("Track: \"\(name)\" — no container"); continue
    }
    // Find 0x260e blocks directly inside this container
    // (but NOT inside a nested 0x261b)
    let nested261b = all261b.filter { b in isInside(b, container) && b.off != container.off }
    let directPaths = all260e.filter { e in
        isInside(e, container) && !nested261b.contains(where: { isInside(e, $0) })
    }

    var pathStrings: [String] = []
    for e in directPaths.sorted(by: { $0.off < $1.off }) {
        let limit = e.off + e.size
        // Try offset 36 first (known offset), then scan all multiples of 4
        var found: String? = nil
        for tryOff in [36, 32, 28, 40, 24, 20, 16, 12, 8, 4, 0, 44, 48] {
            if let s = lpStr(at: e.off + tryOff, limit: limit), s.count >= 2 {
                found = s; break
            }
        }
        if let s = found { pathStrings.append(s) }
    }

    print("Track: \"\(name)\"  paths: \(pathStrings.isEmpty ? "(none)" : pathStrings.joined(separator: " | "))")
}
