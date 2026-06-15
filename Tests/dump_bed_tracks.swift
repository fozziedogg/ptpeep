#!/usr/bin/env swift
// Show the 0x102d strip name for Atmos BED routing containers,
// so we can see which PT track is feeding which Atmos bed bus.
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
    default:   return (1,  "?\(String(format:"%02x",b))")
    }
}

let blocks = scanBlocks().sorted { $0.off < $1.off }
let all261b = blocks.filter { $0.ct == 0x261b }
let all260d = blocks.filter { $0.ct == 0x260d }
let all260e = blocks.filter { $0.ct == 0x260e }

// Get 0x251a format bytes for cross-reference
var nameToFmt = [String: UInt8]()
if let b2519 = blocks.first(where: { $0.ct == 0x2519 }) {
    let pStart = b2519.off, pEnd = b2519.off + b2519.size
    var seen = Set<String>()
    for sub in blocks.filter({ $0.ct == 0x251a && $0.off >= pStart && $0.off + $0.size <= pEnd }) {
        let p = sub.off
        guard p + 6 <= sub.off + sub.size else { continue }
        let nl = Int(u32le(p+2)); guard nl >= 1, nl <= 256 else { continue }
        let nameEnd = p + 6 + nl
        guard nameEnd <= sub.off + sub.size else { continue }
        guard let name = String(bytes: data[(p+6)..<nameEnd], encoding: .utf8),
              seen.insert(name).inserted else { continue }
        nameToFmt[name] = nameEnd < sub.off + sub.size ? data[nameEnd] : 0xff
    }
}

print("File: \(path)\n")
print("Atmos BED routing containers (strip name → output path):")
print(String(repeating: "─", count: 70))

for container in all261b {
    let cStart = container.off, cEnd = container.off + container.size

    // Read strip name from 0x102d
    guard let strip = blocks.first(where: { $0.ct == 0x102d && $0.off >= cStart && $0.off + $0.size <= cEnd }) else { continue }
    let nameOff = strip.off + 9
    guard nameOff + 4 <= strip.off + strip.size else { continue }
    let nl = Int(u32le(nameOff)); guard nl >= 1, nl <= 64 else { continue }
    let nameEnd = nameOff + 4 + nl
    guard nameEnd <= strip.off + strip.size else { continue }
    guard let stripName = String(bytes: data[(nameOff+4)..<nameEnd], encoding: .utf8) else { continue }

    // Find routing blocks
    let routingBlocks = all260e.filter { e in
        guard e.off >= cStart, e.off + e.size <= cEnd else { return false }
        return all260d.contains(where: { d in
            d.off >= cStart && d.off + d.size <= cEnd &&
            e.off >= d.off && e.off + e.size <= d.off + d.size
        })
    }

    var outputPath: String? = nil
    var flagBytes = ""
    var tag = "PLAIN"

    for pathBlock in routingBlocks {
        guard pathBlock.size >= 2,
              !(data[pathBlock.off] == 0xff && data[pathBlock.off+1] == 0xff) else { continue }
        let lpOff = pathBlock.off + 36
        guard lpOff + 4 <= pathBlock.off + pathBlock.size else { continue }
        let sl = Int(u32le(lpOff)); guard sl > 0, sl <= 256 else { continue }
        guard lpOff + 4 + sl <= pathBlock.off + pathBlock.size else { continue }
        guard let s = String(bytes: data[(lpOff+4)..<(lpOff+4+sl)], encoding: .utf8), !s.isEmpty else { continue }

        if outputPath == nil {
            outputPath = s
            let flagOff = lpOff + 4 + sl
            let dumpCount = min(20, pathBlock.off + pathBlock.size - flagOff)
            if dumpCount > 0 {
                flagBytes = (0..<dumpCount).map { String(format: "%02x", data[flagOff + $0]) }.joined(separator: " ")
                if flagOff + 12 <= pathBlock.off + pathBlock.size {
                    let b0 = data[flagOff], b1 = data[flagOff+1], b2 = data[flagOff+2]
                    let b11 = data[flagOff+11]
                    if b2 != 0xff && b2 != 0x00 && b0 == 0x00 && b1 == 0x00 { tag = "OBJ" }
                    else if b11 != 0xff { tag = "BED" }
                }
            }
        }
        break
    }

    guard tag == "BED", let outPath = outputPath else { continue }

    // Cross-reference strip name against 0x251a
    let fmtByte = nameToFmt[stripName]
    let fmtStr: String
    if let fb = fmtByte {
        let (count, label) = channelInfo(fb)
        fmtStr = "0x\(String(format:"%02x",fb)) (\(label), \(count)ch)"
    } else {
        fmtStr = "(not in 0x251a)"
    }

    print("  Strip: \"\(stripName)\"")
    print("    Output: \"\(outPath)\"")
    print("    0x251a fmt: \(fmtStr)")
    print("    flagOff: \(flagBytes)")
    print()
}
