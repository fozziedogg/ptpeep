#!/usr/bin/env swift
// Dump 0x251a format byte and channel count for specific track names
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/honeybunch_PeepTest.ptx"
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

func channelInfo(_ b: UInt8) -> (Int, String) {
    switch b {
    case 0x00: return (1,  "Mono")
    case 0x01: return (2,  "Stereo")
    case 0x02: return (3,  "LCR")
    case 0x03: return (4,  "LCRS")
    case 0x04: return (4,  "Quad")
    case 0x05: return (5,  "5.0")
    case 0x06: return (6,  "5.1")
    case 0x07: return (6,  "6.0")
    case 0x08: return (7,  "6.1")
    case 0x09: return (7,  "7.0")
    case 0x0A: return (8,  "7.1")
    case 0x0B: return (9,  "7.0.2")
    case 0x0C: return (10, "7.1.2")
    case 0x0D: return (11, "7.0.4")
    case 0x0E: return (12, "7.1.4")
    case 0x0F: return (13, "9.0.4")
    case 0x10: return (14, "9.1.4")
    default:   return (1,  "Mono/?\(String(format:"%02x",b))")
    }
}

let blocks = scanBlocks()
guard let b2519 = blocks.first(where: { $0.ct == 0x2519 }) else { print("No 0x2519 block"); exit(1) }
let pStart = b2519.off, pEnd = b2519.off + b2519.size

var seen = Set<String>()
for sub in blocks.filter({ $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd }).sorted(by: { $0.off < $1.off }) {
    let p = sub.off
    guard p + 6 <= sub.off + sub.size else { continue }
    let nl = Int(u32le(p+2)); guard nl >= 1, nl <= 256 else { continue }
    let nameEnd = p + 6 + nl
    guard nameEnd <= sub.off + sub.size else { continue }
    guard let name = String(bytes: data[(p+6)..<nameEnd], encoding: .utf8),
          seen.insert(name).inserted else { continue }

    let fmtByte = nameEnd < sub.off + sub.size ? data[nameEnd] : 0xff
    let (count, label) = channelInfo(fmtByte)

    // Print all tracks, highlight Atmos-relevant ones
    let marker = (name.contains("Dialog") || name.contains("Source Mus") || name.contains("DX") || name.contains("Floor")) ? " ◀" : ""
    let namePad = name.padding(toLength: 30, withPad: " ", startingAt: 0)
    let labelPad = label.padding(toLength: 8, withPad: " ", startingAt: 0)
    print(String(format: "  %@  fmt=0x%02x  %d ch  %@%@", namePad, fmtByte, count, labelPad, marker))
}
