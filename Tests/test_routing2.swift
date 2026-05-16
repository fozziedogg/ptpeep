#!/usr/bin/env swift
// test_routing2.swift — Debug lastChildEnd and sentinel scan for Printmaster
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/PeepTest.ptx"
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("Cannot read \(path)"); exit(1) }

func xorDecode(_ raw: Data) -> Data? {
    guard raw.count > 0x14, raw[0x12] == 0x05 else { return nil }
    let xv = raw[0x13]; let mul: UInt16 = 11; var delta: UInt8 = 0
    for i: UInt16 in 0...255 { if (i * mul) & 0xff == UInt16(xv) { delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break } }
    var t = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { t[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }
    var d = raw
    let chunkSize = 4096
    for chunk in stride(from: chunkSize, to: raw.count, by: chunkSize) {
        let xorByte = t[(chunk >> 12) & 0xff]
        guard xorByte != 0 else { continue }
        let end = min(chunk + chunkSize, raw.count)
        for i in chunk..<end { d[i] = raw[i] ^ xorByte }
    }
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
let all261b = blocks.filter { $0.ct == 0x261b }
let all102d = blocks.filter { $0.ct == 0x102d }

// Focus on Printmaster.dup1 — the first 0x261b whose 0x102d strip contains "Printmaster"
for container in all261b.sorted(by: { $0.off < $1.off }) {
    let cStart = container.off; let cEnd = container.off + container.size
    guard let strip = all102d.first(where: { $0.off >= cStart && $0.off + $0.size <= cEnd }) else { continue }
    let nameOff = strip.off + 9
    guard nameOff + 4 <= data.count else { continue }
    let nl = Int(u32le(data, nameOff))
    guard nl >= 1, nl <= 64, nameOff + 4 + nl <= data.count else { continue }
    guard let name = String(bytes: data[(nameOff+4)..<(nameOff+4+nl)], encoding: .utf8) else { continue }

    guard name.contains("Printmaster") || name == "Master Bus" else { continue }

    // Find lastChildEnd
    let childBlocks = blocks.filter { $0.off >= cStart && $0.off + $0.size <= cEnd }
    let lastChildEnd = childBlocks.map { $0.off + $0.size }.max() ?? cStart

    print("=== \"\(name)\" ===")
    print("Container: off=0x\(String(cStart, radix:16)) size=\(container.size)")
    print("Child blocks: \(childBlocks.count)")
    print("lastChildEnd: \(lastChildEnd - cStart) (relative to container start)")

    // Show all child blocks sorted by their END position (last ones first)
    let sorted = childBlocks.sorted { ($0.off + $0.size) > ($1.off + $1.size) }
    print("Last 10 child blocks by end position:")
    for b in sorted.prefix(10) {
        print("  ct=0x\(String(format:"%04x", b.ct)) off=+\(b.off - cStart) size=\(b.size) ends=+\(b.off + b.size - cStart)")
    }

    // Now scan from lastChildEnd for the sentinel pattern
    print("\nSentinel scan from lastChildEnd (\(lastChildEnd - cStart)) to cEnd (\(container.size)):")
    var pos = lastChildEnd
    var found = false
    while pos + 9 < cEnd {
        if data[pos] == 0 && data[pos+1] == 0 && data[pos+2] == 0 && data[pos+3] == 0 {
            let lpOff = pos + 9
            let rel = pos - cStart
            print("  Sentinel found at +\(rel), lpOff=+\(lpOff - cStart)")
            if lpOff + 4 <= cEnd {
                let len = Int(u32le(data, lpOff))
                print("  LP len = \(len)")
                if len > 0, len <= 128, lpOff + 4 + len <= cEnd {
                    let bytes = data[(lpOff+4)..<(lpOff+4+len)]
                    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                       let s = String(bytes: bytes, encoding: .utf8) {
                        print("  LP string = \"\(s)\"")
                        found = true
                        break
                    }
                }
            }
        }
        pos += 1
    }
    if !found { print("  No input path found.") }
    print()
}
