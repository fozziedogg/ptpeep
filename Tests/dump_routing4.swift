#!/usr/bin/env swift
// dump_routing4.swift
// Correctly maps routing by finding 0x261b blocks that CONTAIN both a 0x102d strip
// and 0x260d/0x260e path blocks. Uses global block list to avoid deep recursion.
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

// Check if a block B is contained within block A
func isInside(_ inner: Block, _ outer: Block) -> Bool {
    return inner.off >= outer.off && inner.off + inner.size <= outer.off + outer.size
}

// LP string reader
func lpStr(at off: Int, limit: Int) -> String? {
    guard off + 4 <= limit else { return nil }
    let len = Int(u32le(data, off))
    guard len > 0, len <= 512, off + 4 + len <= limit else { return nil }
    return String(bytes: data[(off+4)..<(off+4+len)], encoding: .utf8)
}

// Track name from 0x102d: data starts with 0x5a sub-block header (9 bytes), then LP string
func trackName(_ b: Block) -> String {
    guard b.size > 9, data[b.off] == 0x5a else {
        return lpStr(at: b.off, limit: b.off + b.size) ?? "?"
    }
    return lpStr(at: b.off + 9, limit: b.off + b.size) ?? "?"
}

let allStrips  = blocks.filter { $0.ct == 0x102d }
let all261b    = blocks.filter { $0.ct == 0x261b }
let all260d    = blocks.filter { $0.ct == 0x260d }
let all260e    = blocks.filter { $0.ct == 0x260e }

print("0x102d (strips): \(allStrips.count)")
print("0x261b (routing containers): \(all261b.count)")
print("0x260d (path blocks): \(all260d.count)")
print("0x260e (path name strings): \(all260e.count)\n")

// For each 0x102d, find the 0x261b that contains it
for strip in allStrips.sorted(by: { $0.off < $1.off }) {
    let name = trackName(strip)

    // Find innermost 0x261b containing this strip
    let containers = all261b.filter { isInside(strip, $0) }.sorted { $0.size < $1.size }
    guard let container = containers.first else {
        print("Track: \"\(name)\" — no 0x261b container found")
        continue
    }

    // Find all 0x260e blocks inside this container (path name strings)
    let pathNames = all260e.filter { isInside($0, container) }

    // Find all 0x260d blocks inside this container (path descriptors)
    let pathBlocks = all260d.filter { isInside($0, container) }

    print("Track: \"\(name)\"")
    print("  0x261b @0x\(String(container.off, radix:16)) sz=\(container.size)")
    print("  0x260d count: \(pathBlocks.count)")

    // For each 0x260d, find its 0x260e(s) and show the first byte of 0x260d data as role
    for pd in pathBlocks.sorted(by: { $0.off < $1.off }) {
        let role = pd.off < pd.off + pd.size ? data[pd.off] : 0xff
        let names = all260e.filter { isInside($0, pd) }.compactMap { e -> String? in
            lpStr(at: e.off, limit: e.off + e.size)
        }

        // Also show the first 8 bytes of 0x260d for role analysis
        let end = min(pd.off + pd.size, pd.off + 32)
        let hex = (pd.off..<end).map { String(format: "%02x", data[$0]) }.joined(separator: " ")

        print("    0x260d @0x\(String(pd.off, radix:16)) sz=\(pd.size) byte[0]=0x\(String(format:"%02x", role)) names=\(names)")
        print("           hex: \(hex)")
    }

    // Also dump all 0x260e LP strings in container (some may not be under 0x260d)
    let allNames = pathNames.compactMap { lpStr(at: $0.off, limit: $0.off + $0.size) }
    print("  All path strings: \(allNames)")
    print()
}

// ── Also show what's in a single 0x261b to understand layout ─────────────

print("\n── Detailed layout of 0x261b for 'SVB_102_2.0 DIA_Final_01' ──\n")
if let strip4 = allStrips.sorted(by: { $0.off < $1.off }).first(where: {
    trackName($0).contains("DIA")
}) {
    let containers = all261b.filter { isInside(strip4, $0) }.sorted { $0.size < $1.size }
    if let c = containers.first {
        print("0x261b @0x\(String(c.off, radix:16)) sz=\(c.size)")
        // Dump all child blocks of any type
        let children = blocks.filter { b in
            b.off >= c.off && b.off + b.size <= c.off + c.size && b.ct != 0x261b
        }.sorted { $0.off < $1.off }
        for ch in children.prefix(40) {
            let relOff = ch.off - c.off
            let preview = min(16, ch.size)
            let hex = (ch.off..<(ch.off+preview)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print("  +\(relOff) ct=0x\(String(format:"%04x", ch.ct)) sz=\(ch.size) | \(hex)")
        }
    }
}
