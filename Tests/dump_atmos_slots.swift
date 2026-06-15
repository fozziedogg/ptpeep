#!/usr/bin/env swift
// dump_atmos_slots.swift
// Dump the full bytes after the LP output-path string for every track
// in a PTX file that has an output path.  Used to reverse-engineer
// Dolby Atmos renderer slot / bed-channel encoding.
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/honeybunch_PeepTest.ptx"
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("Cannot read \(path)"); exit(1) }

// ── XOR decode ────────────────────────────────────────────────────────────────
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

// ── Block scanner ─────────────────────────────────────────────────────────────
struct Block { var ct: UInt16; var off: Int; var size: Int }
func u32le(_ i: Int) -> UInt32 {
    guard i+4 <= data.count else { return 0 }
    return UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
}
func scanBlocks() -> [Block] {
    var blocks = [Block](); var i = 0x1f
    while i + 9 <= data.count {
        guard data[i] == 0x5a else { i += 1; continue }
        let sz = Int(u32le(i+3))
        let ct = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
        guard sz > 0, sz < 50_000_000, i + 9 + sz <= data.count else { i += 1; continue }
        blocks.append(Block(ct: ct, off: i+9, size: sz))
        i += 1
    }
    return blocks
}
func inside(_ inner: Block, _ outer: Block) -> Bool {
    inner.off >= outer.off && inner.off + inner.size <= outer.off + outer.size
}

let blocks = scanBlocks()

// ── Collect track names from 0x251a sub-blocks of 0x2519 ─────────────────────
var uidToName = [String: String]()
if let b2519 = blocks.first(where: { $0.ct == 0x2519 }) {
    let pStart = b2519.off, pEnd = b2519.off + b2519.size
    var seen = Set<String>()
    for sub in blocks.filter({ $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd }).sorted(by: { $0.off < $1.off }) {
        let p = sub.off
        guard p + 6 <= sub.off + sub.size,
              let nl = Optional(u32le(p+2)), nl >= 1, nl <= 256 else { continue }
        let nameEnd = p + 6 + Int(nl)
        guard nameEnd + 18 <= sub.off + sub.size,
              let name = String(bytes: data[(p+6)..<nameEnd], encoding: .utf8),
              seen.insert(name).inserted else { continue }
        let uidHex = (nameEnd+10..<nameEnd+18).map { String(format: "%02x", data[$0]) }.joined()
        uidToName[uidHex] = name
    }
}

// ── Walk 0x261b containers ────────────────────────────────────────────────────
let containers261b = blocks.filter { $0.ct == 0x261b }.sorted { $0.off < $1.off }
let all260e = blocks.filter { $0.ct == 0x260e }
let all260d = blocks.filter { $0.ct == 0x260d }
let all261c = blocks.filter { $0.ct == 0x261c }

// Resolve track name from 0x261c → UID → name
func trackName(for container: Block) -> String {
    guard let c261c = all261c.first(where: { inside($0, container) }) else { return "(unknown)" }
    let p = c261c.off
    guard p + 18 <= c261c.off + c261c.size else { return "(unknown)" }
    let uidHex = (p+10..<p+18).map { String(format: "%02x", data[$0]) }.joined()
    return uidToName[uidHex] ?? "(uid:\(uidHex.prefix(8)))"
}

print("File: \(path)")
print(String(repeating: "═", count: 80))

var printed = 0
for container in containers261b {
    let cStart = container.off, cEnd = container.off + container.size
    // Find 0x260e inside a 0x260d inside this container
    guard let pathBlock = all260e.first(where: { e in
        guard e.off >= cStart, e.off + e.size <= cEnd else { return false }
        return all260d.contains(where: { d in
            d.off >= cStart && d.off + d.size <= cEnd &&
            e.off >= d.off && e.off + e.size <= d.off + d.size
        })
    }) else { continue }

    // Validate first 2 bytes != ff ff
    guard pathBlock.size >= 2,
          !(data[pathBlock.off] == 0xff && data[pathBlock.off+1] == 0xff) else { continue }

    // Read LP string at offset +36
    let lpOff = pathBlock.off + 36
    guard lpOff + 4 <= pathBlock.off + pathBlock.size,
          let sl = Optional(u32le(lpOff)), sl > 0, sl <= 256,
          lpOff + 4 + Int(sl) <= pathBlock.off + pathBlock.size,
          let outputPath = String(bytes: data[(lpOff+4)..<(lpOff+4+Int(sl))], encoding: .utf8),
          !outputPath.isEmpty else { continue }

    let flagOff = lpOff + 4 + Int(sl)
    let name = trackName(for: container)

    // Classify
    var tag = "PLAIN"
    if flagOff + 12 <= pathBlock.off + pathBlock.size {
        let b0 = data[flagOff], b1 = data[flagOff+1], b2 = data[flagOff+2]
        let b11 = data[flagOff+11]
        if b2 != 0xff && b2 != 0x00 && b0 == 0x00 && b1 == 0x00 { tag = "OBJ" }
        else if b11 != 0xff { tag = "BED" }
    }

    // Dump full bytes after LP string (up to 32 bytes)
    let dumpCount = min(32, pathBlock.off + pathBlock.size - flagOff)
    let flagBytes = (0..<dumpCount).map { String(format: "%02x", data[flagOff + $0]) }.joined(separator: " ")

    print("\n[\(tag)] \(name)")
    print("  → \"\(outputPath)\"  (260e sz=\(pathBlock.size))")
    print("  flagOff bytes: \(flagBytes)")

    // For OBJ: highlight the slot byte
    if tag == "OBJ" && dumpCount >= 3 {
        print("  OBJ slot: \(data[flagOff+2]) (0x\(String(format: "%02x", data[flagOff+2])))")
    }
    // For BED: highlight the group byte
    if tag == "BED" && dumpCount >= 12 {
        print("  BED group byte [+11]: 0x\(String(format: "%02x", data[flagOff+11]))")
    }
    printed += 1
}

if printed == 0 { print("No routed tracks found.") }
print("\n" + String(repeating: "═", count: 80))
print("Total: \(printed) routed tracks")
