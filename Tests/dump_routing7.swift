#!/usr/bin/env swift
// dump_routing7.swift
// Hex dump the region around the input path LP string in Printmaster and Master Bus
// to identify the exact block type and byte structure.
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
func u32le(_ i: Int) -> UInt32 {
    guard i+4 <= data.count else { return 0 }
    return UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
}
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

let blocks    = scanBlocks(data)
let all261b   = blocks.filter { $0.ct == 0x261b }

// Hex dump a region with annotations
func hexDump(from start: Int, to end: Int, base: Int, label: String) {
    print("\n── \(label) ──")
    var pos = start
    while pos < end {
        let lineEnd = min(pos + 16, end)
        let relOff  = pos - base
        var hex = ""; var asc = ""
        for i in pos..<lineEnd {
            hex += String(format: "%02x ", data[i])
            asc += data[i] >= 32 && data[i] < 127 ? String(UnicodeScalar(data[i])) : "."
        }
        print(String(format: "  +%04d (0x%05x): %-49s %s", relOff, pos, hex, asc))
        pos = lineEnd
    }
}

// Printmaster.dup1 — path strings at +741 (STERO OUT) and +1081 (LoRo.Stereo)
let printmasterOff = 0x44ac6
let printmasterSize = 1317
print("=== Printmaster.dup1 0x261b @0x\(String(printmasterOff, radix:16)) sz=\(printmasterSize) ===")
// Dump from +980 to end (where input path lives)
hexDump(from: printmasterOff + 980, to: printmasterOff + printmasterSize,
        base: printmasterOff, label: "Printmaster: from +980 to end (input path region)")

// Master Bus — path strings at +7744 (LoRo.Stereo output) and +8086 (FULL MIX input)
let masterBusOff = 0x45993
let masterBusSize = 8319
print("\n=== Master Bus 0x261b @0x\(String(masterBusOff, radix:16)) sz=\(masterBusSize) ===")
hexDump(from: masterBusOff + 7680, to: masterBusOff + masterBusSize,
        base: masterBusOff, label: "Master Bus: from +7680 to end (both output and input region)")

// Also: brute force find ALL 0x260e-like blocks by looking for the 12-null + LP pattern
// regardless of block type
print("\n── Searching for input path pattern (12 zeros + LP string) in Printmaster ──")
let pEnd = printmasterOff + printmasterSize
var pos = printmasterOff + 700  // start past output path
while pos + 52 < pEnd {
    // Check for 12 consecutive zero bytes followed by a valid LP string
    let allZeros = (0..<12).allSatisfy { data[pos + $0] == 0x00 }
    if allZeros {
        let lenOff = pos + 12
        let len = Int(u32le(lenOff))
        if len > 0, len <= 64, lenOff + 4 + len <= pEnd {
            if let s = String(bytes: data[(lenOff+4)..<(lenOff+4+len)], encoding: .utf8),
               s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) {
                print("  Found at +\(pos - printmasterOff): 12 zeros + len=\(len) + \"\(s)\"")
                // Dump 32 bytes before to identify the block header
                let dumpStart = max(printmasterOff, pos - 32)
                hexDump(from: dumpStart, to: lenOff + 4 + len + 4,
                        base: printmasterOff, label: "Context")
            }
        }
    }
    pos += 1
}

// Same for Master Bus
print("\n── Searching for input path pattern in Master Bus (from +7300) ──")
pos = masterBusOff + 7300
let mEnd = masterBusOff + masterBusSize
while pos + 52 < mEnd {
    let allZeros = (0..<12).allSatisfy { data[pos + $0] == 0x00 }
    if allZeros {
        let lenOff = pos + 12
        let len = Int(u32le(lenOff))
        if len > 0, len <= 64, lenOff + 4 + len <= mEnd {
            if let s = String(bytes: data[(lenOff+4)..<(lenOff+4+len)], encoding: .utf8),
               s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) {
                print("  Found at +\(pos - masterBusOff): 12 zeros + len=\(len) + \"\(s)\"")
                let dumpStart = max(masterBusOff, pos - 32)
                hexDump(from: dumpStart, to: lenOff + 4 + len + 4,
                        base: masterBusOff, label: "Context")
            }
        }
    }
    pos += 1
}
