import Foundation

// Dump all 0x1052 blocks in full to decode the fade format.
// Also show the 0x1050 wrapper extra bytes (bytes after the embedded 0x104f)
// which may contain clip gain.

struct Dump1052Fades {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_1052_fades <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // ── 1. All 0x1052 blocks in full ─────────────────────────────────────
        let fadeBlocks = blocks.filter { $0.ct == 0x1052 }
        print("=== 0x1052 blocks (potential fades): \(fadeBlocks.count) total ===\n")
        for (i, b) in fadeBlocks.enumerated() {
            let end = b.off + b.size
            let hex = (b.off..<end).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print("[\(i)] @\(b.off) size=\(b.size)")
            print("  hex: \(hex)")
            // Try to interpret: scan for inner 0x104f to find clip reference
            // The 0x104f inside will tell us which clip this fade belongs to
            if let clipRef = findInner104f(data: data, from: b.off, length: b.size) {
                print("  → clip ref at +\(clipRef.relOff): \(clipRef.desc)")
            }
            // Show any 4-byte LE integers that might be sample counts (fade lengths)
            let u32s = stride(from: b.off, to: end - 3, by: 4).map {
                UInt32(data[$0]) | UInt32(data[$0+1]) << 8 | UInt32(data[$0+2]) << 16 | UInt32(data[$0+3]) << 24
            }
            print("  u32s: \(u32s.map { String(format: "0x%08x = %d", $0, $0) }.joined(separator: ", "))")
            print()
        }

        // ── 2. 0x1050 wrapper: show bytes AFTER the embedded 0x104f ──────────
        // The 0x1050 is a wrapper; size tells us how many bytes beyond the 0x104f
        // Compare across multiple clips to find clip-gain or other per-clip data.
        let wrappers = blocks.filter { $0.ct == 0x1050 }
        print("\n=== 0x1050 wrappers — bytes AFTER the embedded 0x104f (first 20) ===\n")
        var shown = 0
        for b in wrappers {
            // Find the embedded 0x104f block starting at b.off
            guard b.off + 9 <= data.count,
                  data[b.off] == 0x5a else { continue }
            let innerSize = Int(UInt32(data[b.off+3]) | UInt32(data[b.off+4]) << 8 |
                                UInt32(data[b.off+5]) << 16 | UInt32(data[b.off+6]) << 24)
            let innerType = UInt16(data[b.off+7]) | UInt16(data[b.off+8]) << 8
            guard innerType == 0x104f else { continue }  // confirm inner is 0x104f

            // Bytes in 0x1050 after the inner 0x104f (header 9 + content innerSize):
            let afterOff  = b.off + 9 + innerSize
            let extraBytes = b.size - (9 + innerSize)
            guard afterOff <= b.off + b.size, extraBytes > 0 else {
                print("@\(b.off): no extra bytes")
                shown += 1; if shown >= 20 { break }; continue
            }
            let end = afterOff + extraBytes
            let extraHex = (afterOff..<min(end, afterOff + 32)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            // Also grab inner 0x104f byte0 (mute indicator) and clip ID bytes
            let inner104fByte0 = data[b.off + 9]
            let inner104fBytes2to5 = (b.off+9+2..<b.off+9+6).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print("@\(b.off)  muted=\(inner104fByte0==1)  clipID=[\(inner104fBytes2to5)]  extraBytes(\(extraBytes)): \(extraHex)")
            shown += 1; if shown >= 20 { break }
        }

        // ── 3. Compare 0x104f content bytes 20-36 (unexplored territory) ─────
        print("\n=== 0x104f bytes [20..36] — looking for clip gain or other data ===\n")
        let clips104f = blocks.filter { $0.ct == 0x104f }
        print("  idx  b20-36")
        for (i, b) in clips104f.prefix(20).enumerated() {
            guard b.off + 37 <= data.count else { continue }
            let tail = (b.off+20..<b.off+37).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            let byte0 = data[b.off]
            print("  [\(String(format:"%02d",i))] muted=\(byte0==1)  \(tail)")
        }
    }

    // Find the first 0x104f block starting within [from, from+length)
    struct ClipRef { let relOff: Int; let desc: String }
    static func findInner104f(data: Data, from: Int, length: Int) -> ClipRef? {
        var i = from
        while i + 9 <= from + length {
            guard data[i] == 0x5a else { i += 1; continue }
            let sz = Int(UInt32(data[i+3]) | UInt32(data[i+4]) << 8 |
                        UInt32(data[i+5]) << 16 | UInt32(data[i+6]) << 24)
            let ct = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
            if ct == 0x104f, sz == 37, i + 9 + sz <= data.count {
                let cBytes = (i+9..<i+9+sz).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
                return ClipRef(relOff: i - from, desc: cBytes)
            }
            i += 1
        }
        return nil
    }

    static func scanBlocks(_ data: Data) -> [Block] {
        var blocks = [Block]()
        var i = 0x1f
        while i + 9 <= data.count {
            guard data[i] == 0x5a else { i += 1; continue }
            let size = Int(UInt32(data[i+3]) | UInt32(data[i+4]) << 8 |
                           UInt32(data[i+5]) << 16 | UInt32(data[i+6]) << 24)
            let ct = UInt16(data[i+7]) | UInt16(data[i+8]) << 8
            guard size > 0, size < 50_000_000, i + 9 + size <= data.count else { i += 1; continue }
            blocks.append(Block(ct: ct, off: i + 9, size: size))
            i += 1
        }
        return blocks
    }

    static func xorDecode(_ raw: Data) -> Data? {
        guard raw.count > 0x13 else { return nil }
        let key = raw[0x13]
        if key == 0 { return raw }
        var out = raw
        for i in 0x14..<out.count { out[i] ^= key }
        return out
    }
}

Dump1052Fades.run()
