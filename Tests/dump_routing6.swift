#!/usr/bin/env swift
// dump_routing6.swift
// Brute-force scan each 0x261b container for ALL LP strings and block types,
// to find where input paths are stored.
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
func u32le(_ i: Int) -> UInt32 { u32le(data, i) }
func lpStr(at off: Int, limit: Int) -> String? {
    guard off + 4 <= limit else { return nil }
    let len = Int(u32le(off))
    guard len > 0, len <= 256, off + 4 + len <= limit else { return nil }
    let s = String(bytes: data[(off+4)..<(off+4+len)], encoding: .utf8)
    return s?.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) == true ? s : nil
}
func trackName(_ b: Block) -> String {
    guard b.size > 9, data[b.off] == 0x5a else { return lpStr(at: b.off, limit: b.off + b.size) ?? "?" }
    return lpStr(at: b.off + 9, limit: b.off + b.size) ?? "?"
}

let blocks    = scanBlocks(data)
let allStrips = blocks.filter { $0.ct == 0x102d }
let all261b   = blocks.filter { $0.ct == 0x261b }

// Known routing strings to watch for
let knownPaths: Set<String> = ["LoRo.Stereo","STERO OUT","FULL MIX","OUT 1-2","OUT 1","No Output","None"]

// Focus on tracks with known inputs
let tracksWithInput = ["Printmaster", "Master Bus", "SVB_BTS"]

print("── Brute-force LP string scan inside each 0x261b container ──\n")
for strip in allStrips.sorted(by: { $0.off < $1.off }) {
    let name = trackName(strip)
    let containers = all261b.filter { isInside(strip, $0) }.sorted { $0.size < $1.size }
    guard let c = containers.first else { continue }

    // Scan every byte position for LP strings
    var found: [(Int, String)] = []
    var pos = c.off
    let end = c.off + c.size
    while pos + 4 < end {
        if let s = lpStr(at: pos, limit: end), s.count >= 3 {
            found.append((pos - c.off, s))
            pos += 4 + s.utf8.count  // skip past this string
        } else {
            pos += 1
        }
    }

    // Filter to interesting strings (routing-related, length > 2, not internal garbage)
    let routing = found.filter { (_, s) in
        s.count >= 3 && (
            knownPaths.contains(s) ||
            s.contains("Bus") || s.contains("Mix") || s.contains("Out") ||
            s.contains("Stereo") || s.contains("in") || s.contains("LoRo") ||
            s.contains("FULL") || s.contains("OUT") || s.contains("STE") ||
            s.count > 4
        )
    }

    // Only print tracks that have routing OR are tracks we care about
    let interesting = tracksWithInput.contains(where: { name.contains($0) })
    if routing.isEmpty && !interesting { continue }

    print("Track: \"\(name)\" [0x261b @0x\(String(c.off, radix:16)) sz=\(c.size)]")
    for (off, s) in found.prefix(40) {
        let marker = knownPaths.contains(s) ? " ◀ PATH" : ""
        print("  +\(off): \"\(s)\"\(marker)")
    }
    print()
}

// ── Also dump all block types inside the Master Bus 0x261b ────────────────

print("\n── All child blocks inside Master Bus 0x261b ──\n")
if let masterStrip = allStrips.first(where: { trackName($0) == "Master Bus" }),
   let c = all261b.filter({ isInside(masterStrip, $0) }).sorted(by: { $0.size < $1.size }).first {

    let children = blocks.filter { b in
        b.off >= c.off && b.off + b.size <= c.off + c.size
    }.sorted { $0.off < $1.off }

    print("0x261b @0x\(String(c.off, radix:16)) sz=\(c.size)")
    for ch in children {
        let rel = ch.off - c.off
        let preview = min(32, ch.size)
        let hex = (ch.off..<(ch.off+preview)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
        print("  +\(rel) ct=0x\(String(format:"%04x", ch.ct)) sz=\(ch.size) | \(hex)")
    }
}

// ── Check: what comes right after the 0x261b container for Master Bus? ────

print("\n── Bytes just BEFORE the 0x261b container for Master Bus (looking for input block) ──\n")
if let masterStrip = allStrips.first(where: { trackName($0) == "Master Bus" }),
   let c = all261b.filter({ isInside(masterStrip, $0) }).sorted(by: { $0.size < $1.size }).first {

    // Look 256 bytes before the container
    let lookStart = max(0, c.off - 256)
    let hex = (lookStart..<c.off).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
    let asc = (lookStart..<c.off).map { data[$0] >= 32 && data[$0] < 127 ? String(UnicodeScalar(data[$0])) : "." }.joined()
    print("hex: \(hex)")
    print("asc: \(asc)")

    // Also check for LP strings in this region
    var pos = lookStart
    while pos + 4 < c.off {
        if let s = lpStr(at: pos, limit: c.off), s.count >= 3 {
            print("LP string at 0x\(String(pos, radix:16)): \"\(s)\"")
            pos += 4 + s.utf8.count
        } else { pos += 1 }
    }
}

// ── Look at what precedes the SVB_BTS container too ──────────────────────

print("\n── Inside Printmaster.dup1 0x261b (full LP string list) ──\n")
if let strip = allStrips.first(where: { trackName($0).contains("Printmaster") }),
   let c = all261b.filter({ isInside(strip, $0) }).sorted(by: { $0.size < $1.size }).first {

    let children = blocks.filter { b in
        b.off >= c.off && b.off + b.size <= c.off + c.size
    }.sorted { $0.off < $1.off }

    print("0x261b @0x\(String(c.off, radix:16)) sz=\(c.size)")
    for ch in children {
        let rel = ch.off - c.off
        let preview = min(48, ch.size)
        let hex = (ch.off..<(ch.off+preview)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
        let asc = (ch.off..<(ch.off+preview)).map { data[$0] >= 32 && data[$0] < 127 ? String(UnicodeScalar(data[$0])) : "." }.joined()
        // Also check for LP string at offset 36
        let path36 = lpStr(at: ch.off + 36, limit: ch.off + ch.size)
        let pathNote = path36 != nil ? " → +36:\"\(path36!)\"" : ""
        print("  +\(rel) ct=0x\(String(format:"%04x", ch.ct)) sz=\(ch.size)\(pathNote)")
        if ch.ct == 0x260e || ch.ct == 0x260d || ch.ct == 0x260a || ch.ct == 0x260c {
            print("    hex: \(hex)")
            print("    asc: \(asc)")
        }
    }
}
