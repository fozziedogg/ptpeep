#!/usr/bin/env swift
// Show output path + flagOff bytes for a specific strip name
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/honeybunch_PeepTest.ptx"
let target = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "DX 7.1 Floor"
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

let blocks = scanBlocks().sorted { $0.off < $1.off }
let all261b = blocks.filter { $0.ct == 0x261b }
let all260e = blocks.filter { $0.ct == 0x260e }
let all260d = blocks.filter { $0.ct == 0x260d }

for container in all261b {
    let cStart = container.off, cEnd = container.off + container.size
    guard let strip = blocks.first(where: { $0.ct == 0x102d && $0.off >= cStart && $0.off + $0.size <= cEnd }) else { continue }
    let nameOff = strip.off + 9
    guard nameOff + 4 <= strip.off + strip.size else { continue }
    let nl = Int(u32le(nameOff)); guard nl >= 1, nl <= 64 else { continue }
    let nameEnd = nameOff + 4 + nl
    guard nameEnd <= strip.off + strip.size else { continue }
    guard let stripName = String(bytes: data[(nameOff+4)..<nameEnd], encoding: .utf8),
          stripName == target else { continue }

    let routingBlocks = all260e.filter { e in
        guard e.off >= cStart, e.off + e.size <= cEnd else { return false }
        return all260d.contains(where: { d in
            d.off >= cStart && d.off + d.size <= cEnd &&
            e.off >= d.off && e.off + e.size <= d.off + d.size
        })
    }

    print("Strip: \"\(stripName)\" in \(path)")
    for (i, pb) in routingBlocks.enumerated() {
        guard pb.size >= 2, !(data[pb.off] == 0xff && data[pb.off+1] == 0xff) else {
            print("  block[\(i)]: ff ff (no path)"); continue
        }
        let lpOff = pb.off + 36
        guard lpOff + 4 <= pb.off + pb.size else { print("  block[\(i)]: too small"); continue }
        let sl = Int(u32le(lpOff)); guard sl > 0, sl <= 256, lpOff + 4 + sl <= pb.off + pb.size else { continue }
        guard let s = String(bytes: data[(lpOff+4)..<(lpOff+4+sl)], encoding: .utf8) else { continue }
        let flagOff = lpOff + 4 + sl
        let dumpCount = min(21, pb.off + pb.size - flagOff)
        let hex = (0..<dumpCount).map { String(format: "%02x", data[flagOff + $0]) }.joined(separator: " ")
        print("  block[\(i)]: \"\(s)\"  flagOff: \(hex)")
    }
}
