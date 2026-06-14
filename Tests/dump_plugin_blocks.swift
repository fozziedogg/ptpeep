#!/usr/bin/env swift
// Dumps 0x1017 plugin blocks: display name + second string (bundle ID / variant)
// Applies the same XOR decode as PTXBlockDecoder before scanning.
import Foundation

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Tests/Ninvingajuliat Mix 2026May3.ptx"

guard var data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    print("Cannot read \(path)"); exit(1)
}

func u32le(_ d: Data, _ i: Int) -> UInt32 {
    var v: UInt32 = 0; for k in 0..<4 { v |= UInt32(d[i+k]) << (k*8) }; return v
}

// XOR decode (PT 10+)
let fileType = data[0x12]
let xorValue = data[0x13]
guard fileType == 0x05 else { print("Unsupported file type 0x\(String(fileType, radix:16))"); exit(1) }

// genXorDelta
let mul: UInt16 = 11
var delta: UInt8 = 0
for i: UInt16 in 0...255 {
    if (i * mul) & 0xff == UInt16(xorValue) {
        delta = UInt8(truncatingIfNeeded: 256 &- Int(i)); break
    }
}
var table = [UInt8](repeating: 0, count: 256)
for i in 0..<256 { table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff) }

let n = data.count
let chunk = 4096
for start in stride(from: chunk, to: n, by: chunk) {
    let xb = table[(start >> 12) & 0xff]
    guard xb != 0 else { continue }
    for i in start..<min(start+chunk, n) { data[i] ^= xb }
}

// Block scan
struct Block { var ct: UInt16; var dataOff: Int; var dataSize: Int }
var blocks: [Block] = []
var i = 0x1f
while i + 9 <= data.count {
    guard data[i] == 0x5a else { i += 1; continue }
    let size = Int(u32le(data, i+3))
    guard size > 0, size < 50_000_000, i+9+size <= data.count else { i += 1; continue }
    let ct = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
    blocks.append(Block(ct: ct, dataOff: i+9, dataSize: size))
    i += 1
}

print("Total blocks: \(blocks.count)")
let pblocks = blocks.filter { $0.ct == 0x1017 }
print("0x1017 blocks: \(pblocks.count)\n")

for b in pblocks {
    let p = b.dataOff
    guard b.dataSize >= 5 else { continue }
    let typeByte = data[p]
    guard typeByte != 0xff else { continue }

    guard Int(u32le(data, p+1)) >= 1 else { continue }
    let nl = Int(u32le(data, p+1))
    guard nl <= 512, p + 5 + nl <= b.dataOff + b.dataSize else { continue }

    let nameSlice = data[(p+5)..<(p+5+nl)]
    let displayName = String(bytes: nameSlice, encoding: .utf8) ?? "<invalid>"

    // 12 OSType bytes (three 4-char codes)
    let ostypeOff = p + 5 + nl
    var ostypes = ""
    if ostypeOff + 12 <= b.dataOff + b.dataSize {
        for k in 0..<3 {
            let bytes = data[(ostypeOff + k*4)..<(ostypeOff + k*4 + 4)]
            let chars = bytes.map { ($0 >= 32 && $0 < 127) ? Character(UnicodeScalar($0)) : Character(".") }
            ostypes += "'\(String(chars))' "
        }
    }

    // second string: display_name + 12 OSTypes + 4 flags + 3 bytes = +19
    let secondOff = p + 5 + nl + 19
    var secondStr = "<too short>"
    if secondOff + 4 <= b.dataOff + b.dataSize {
        let sl = Int(u32le(data, secondOff))
        if sl <= 512, secondOff + 4 + sl <= b.dataOff + b.dataSize {
            let slice = data[(secondOff+4)..<(secondOff+4+sl)]
            secondStr = sl == 0 ? "<empty>" : (String(bytes: slice, encoding: .utf8) ?? "<binary \(sl) bytes>")
        } else {
            secondStr = "<sl=\(sl) out of bounds>"
        }
    }

    print("type=0x\(String(format: "%02x", typeByte))  display=\"\(displayName)\"")
    print("  OSTypes: \(ostypes)")
    print("  second:  \"\(secondStr)\"")
    print()
}
