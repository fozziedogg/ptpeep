#!/usr/bin/env swift
// test_routing.swift — Verify input + output path extraction against known ground truth.
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/PeepTest.ptx"
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("Cannot read \(path)"); exit(1) }

// XOR decode
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
func isInside(_ inner: Block, _ outer: Block) -> Bool {
    inner.off >= outer.off && inner.off + inner.size <= outer.off + outer.size
}
func lpStr(_ off: Int, limit: Int) -> String? {
    guard off + 4 <= limit else { return nil }
    let len = Int(u32le(data, off))
    guard len > 0, len <= 256, off + 4 + len <= limit else { return nil }
    let bytes = data[(off+4)..<(off+4+len)]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
    return String(bytes: bytes, encoding: .utf8)
}

let blocks = scanBlocks(data)
let all261b = blocks.filter { $0.ct == 0x261b }
let all260d = blocks.filter { $0.ct == 0x260d }
let all260e = blocks.filter { $0.ct == 0x260e }
let all102d = blocks.filter { $0.ct == 0x102d }

// ── Ground truth from user-provided I/O data ──────────────────────────────
// Track name / input / output
let expected: [String: (input: String?, output: String?)] = [
    "PIX":                                  (nil,           nil),         // video
    "GT PIX":                               (nil,           "OUT 1-2"),
    "SVB_BTS_InstagramMix":                 ("LoRo.Stereo", "STERO OUT"),
    "Printmaster":                          ("LoRo.Stereo", "STERO OUT"),
    "Master Bus":                           ("FULL MIX",    "LoRo.Stereo"),
    "SVB_102_2.0 DIA_Final_01":             (nil,           "FULL MIX"),
    "SVB_102_2.0 MUS_Final_01":             (nil,           "FULL MIX"),
    "SVB_102_2.0 SFX_Final_01":             (nil,           "FULL MIX"),
    "Haley 1":                              (nil,           "FULL MIX"),
    "Haley 2":                              (nil,           "FULL MIX"),
    "Haley 1.dup1":                         (nil,           "FULL MIX"),
    "PART ONE.dup1":                        (nil,           "OUT 1-2"),
    "Aux 1":                                (nil,           "STERO OUT"),
]

print("── Routing extraction test ──\n")
var passed = 0; var failed = 0; var total = 0

for container in all261b.sorted(by: { $0.off < $1.off }) {
    let cStart = container.off; let cEnd = container.off + container.size

    // Track name from 0x102d strip
    guard let strip = all102d.first(where: { $0.off >= cStart && $0.off + $0.size <= cEnd }) else { continue }
    let nameOff = strip.off + 9
    guard nameOff + 4 <= data.count else { continue }
    let nl = Int(u32le(data, nameOff))
    guard nl >= 1, nl <= 64, nameOff + 4 + nl <= data.count else { continue }
    guard let name = String(bytes: data[(nameOff+4)..<(nameOff+4+nl)], encoding: .utf8) else { continue }

    // Output path
    var outputPath: String? = nil
    if let pathBlock = all260e.first(where: { e in
        guard e.off >= cStart && e.off + e.size <= cEnd else { return false }
        return all260d.contains(where: { d in
            d.off >= cStart && d.off + d.size <= cEnd &&
            e.off >= d.off && e.off + e.size <= d.off + d.size
        })
    }) {
        let lpOff = pathBlock.off + 36
        if lpOff + 4 <= pathBlock.off + pathBlock.size,
           pathBlock.size >= 2,
           !(data[pathBlock.off] == 0xff && data[pathBlock.off + 1] == 0xff) {
            outputPath = lpStr(lpOff, limit: pathBlock.off + pathBlock.size)
        }
    }

    // Input path: scan from end of last child block (excluding container itself)
    var inputPath: String? = nil
    let lastChildEnd = blocks
        .filter {
            $0.off >= cStart && $0.off + $0.size <= cEnd &&
            !($0.off == cStart && $0.size == container.size)
        }
        .map { $0.off + $0.size }.max() ?? cStart
    var pos = lastChildEnd
    while pos + 9 < cEnd, inputPath == nil {
        if data[pos] == 0 && data[pos+1] == 0 && data[pos+2] == 0 && data[pos+3] == 0 {
            let lpOff = pos + 9
            if lpOff + 4 <= cEnd {
                let len = Int(u32le(data, lpOff))
                if len > 0, len <= 128, lpOff + 4 + len <= cEnd {
                    let bytes = data[(lpOff+4)..<(lpOff+4+len)]
                    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                       let s = String(bytes: bytes, encoding: .utf8) {
                        inputPath = s
                    }
                }
            }
        }
        pos += 1
    }

    let result = (input: inputPath, output: outputPath)
    print("Track: \"\(name)\"")
    print("  input:  \(inputPath ?? "(none)")")
    print("  output: \(outputPath ?? "(none)")")

    if let exp = expected[name] {
        total += 1
        let inputOK  = inputPath  == exp.input
        let outputOK = outputPath == exp.output
        if inputOK && outputOK {
            print("  ✓ PASS")
            passed += 1
        } else {
            print("  ✗ FAIL  expected input=\(exp.input ?? "nil") output=\(exp.output ?? "nil")")
            failed += 1
        }
    }
    print()
}

print("── Results: \(passed)/\(total) passed, \(failed) failed ──")
