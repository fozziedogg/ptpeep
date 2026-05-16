#!/usr/bin/env swift
// dump_routing8.swift
// Identify the block type wrapping the INPUT path in 0x261b containers.
// Searches for 12-null + LP pattern around known input path offsets.
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

func u32le(_ i: Int) -> UInt32 {
    guard i+4 <= data.count else { return 0 }
    return UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
}
func lpStr(at off: Int, limit: Int) -> String? {
    guard off + 4 <= limit else { return nil }
    let len = Int(u32le(off))
    guard len > 0, len <= 256, off + 4 + len <= limit else { return nil }
    guard let s = String(bytes: data[(off+4)..<(off+4+len)], encoding: .utf8) else { return nil }
    return s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) ? s : nil
}

struct Block { var ct: UInt16; var off: Int; var size: Int }
func scanBlocks(_ data: Data) -> [Block] {
    var blocks = [Block](); var i = 0x1f
    while i + 9 <= data.count {
        guard data[i] == 0x5a else { i += 1; continue }
        let size = Int(u32le(i+3))
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

// Hex dump without crashing %s format
func hexDump(from start: Int, count bytes: Int, base: Int, label: String) {
    print("\n── \(label) ──")
    var pos = start
    let end = start + bytes
    while pos < end {
        let lineEnd = min(pos + 16, end)
        let relOff  = pos - base
        var hex = ""
        var asc = ""
        for i in pos..<lineEnd {
            hex += String(format: "%02x ", data[i])
            let c = data[i]
            asc += (c >= 32 && c < 127) ? String(UnicodeScalar(c)) : "."
        }
        // Pad hex to fixed width without %s
        let hexPadded = hex + String(repeating: " ", count: max(0, 49 - hex.count))
        print(String(format: "  +%04d (0x%06x): ", relOff, pos) + hexPadded + asc)
        pos = lineEnd
    }
}

let blocks = scanBlocks(data)

// ── Known 0x261b containers from dump_routing6 ─────────────────────────────
// Printmaster: off=0x44ac6, sz=1317, input "LoRo.Stereo" at +1081
// SVB_BTS:     similar size, input at +1072
// Master Bus:  off=0x45993, sz=8319, input "FULL MIX" at +8086

let printmasterOff  = 0x44ac6
let printmasterSize = 1317
let masterBusOff    = 0x45993
let masterBusSize   = 8319

// ── Step 1: Show context around Printmaster input path ─────────────────────
// Input "LoRo.Stereo" is at container+1081.
// Look at bytes from +1040 to end to see block header before it.
print("=== Printmaster 0x261b: bytes +1040 to end ===")
hexDump(from: printmasterOff + 1040, count: printmasterSize - 1040,
        base: printmasterOff, label: "Printmaster: +1040 → end (input path region)")

// ── Step 2: Show context around Master Bus input path ──────────────────────
// Input "FULL MIX" at container+8086. Show +8040 to end.
print("\n=== Master Bus 0x261b: bytes +8040 to end ===")
hexDump(from: masterBusOff + 8040, count: masterBusSize - 8040,
        base: masterBusOff, label: "Master Bus: +8040 → end (input path region)")

// ── Step 3: Search ALL 0x5a block headers in Printmaster from +1000 ────────
print("\n── Block headers in Printmaster from +1000 ──")
var pos = printmasterOff + 1000
let pEnd = printmasterOff + printmasterSize
while pos + 9 <= pEnd {
    if data[pos] == 0x5a {
        let sz = Int(u32le(pos+3))
        let ct = UInt16(data[pos+7]) | UInt16(data[pos+8]) << 8
        let rel = pos - printmasterOff
        if sz > 0 && sz < 50_000_000 && pos + 9 + sz <= data.count {
            let preview = (pos+9..<min(pos+9+sz, pos+9+32)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            // Check for LP string at +36 in this block
            let pathStr = lpStr(at: pos + 9 + 36, limit: pos + 9 + sz)
            print("  +\(rel): ct=0x\(String(format: "%04x", ct)) sz=\(sz) path=\(pathStr ?? "(none)") | \(preview)")
        }
    }
    pos += 1
}

// ── Step 4: Search ALL 0x5a block headers in Master Bus from +8000 ─────────
print("\n── Block headers in Master Bus from +8000 ──")
pos = masterBusOff + 8000
let mEnd = masterBusOff + masterBusSize
while pos + 9 <= mEnd {
    if data[pos] == 0x5a {
        let sz = Int(u32le(pos+3))
        let ct = UInt16(data[pos+7]) | UInt16(data[pos+8]) << 8
        let rel = pos - masterBusOff
        if sz > 0 && sz < 50_000_000 && pos + 9 + sz <= data.count {
            let preview = (pos+9..<min(pos+9+sz, pos+9+32)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            let pathStr = lpStr(at: pos + 9 + 36, limit: pos + 9 + sz)
            print("  +\(rel): ct=0x\(String(format: "%04x", ct)) sz=\(sz) path=\(pathStr ?? "(none)") | \(preview)")
        }
    }
    pos += 1
}

// ── Step 5: Brute-force find LP string offsets for "LoRo.Stereo" and "FULL MIX"
print("\n── All positions of input path strings in file ──")
let targets = ["LoRo.Stereo", "FULL MIX", "STERO OUT", "STEREO OUT"]
for target in targets {
    guard let tBytes = target.data(using: .utf8) else { continue }
    var searchPos = 0x1f
    while searchPos + 4 + tBytes.count <= data.count {
        let lenAt = Int(u32le(searchPos))
        if lenAt == tBytes.count {
            let slice = data[(searchPos+4)..<(searchPos+4+tBytes.count)]
            if slice.elementsEqual(tBytes) {
                let absOff = searchPos
                // Show what's 50 bytes before
                let ctxStart = max(0, absOff - 50)
                let ctxBytes = (ctxStart..<absOff).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
                print("  \"\(target)\" at 0x\(String(format: "%x", absOff)) (file abs):")
                print("    50 bytes before: \(ctxBytes)")
                // Look for 0x5a header in those 50 bytes
                for back in stride(from: absOff - 1, through: max(0, absOff - 60), by: -1) {
                    if data[back] == 0x5a {
                        let bsz = Int(u32le(back+3))
                        let bct = UInt16(data[back+7]) | UInt16(data[back+8]) << 8
                        if bsz > 0 && bsz < 50_000_000 {
                            print("    ← 0x5a at -\(absOff - back): ct=0x\(String(format: "%04x", bct)) sz=\(bsz)")
                            break
                        }
                    }
                }
            }
        }
        searchPos += 1
    }
}
