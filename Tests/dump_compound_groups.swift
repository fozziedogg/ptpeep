import Foundation

// Dump 0x262b blocks (compound/group clip pool parents) and ALL their 0x2628 children.
// Goal: understand how constituent clips of a PT clip group are stored.
// Each 0x262b parent should contain one or more 0x2628 children — the first being
// the group's "identity" (name + total length) and subsequent ones being constituent clips.

struct DumpCompoundGroups {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_compound_groups <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        let parents262b = blocks.filter { $0.ct == 0x262b }.sorted { $0.off < $1.off }
        let all2628 = blocks.filter { $0.ct == 0x2628 }.sorted { $0.off < $1.off }

        print("=== 0x262b compound pool parents: \(parents262b.count) ===\n")

        let first20 = parents262b.prefix(20)
        for (gi, parent) in first20.enumerated() {
            let pEnd = parent.off + parent.size
            // Find all 0x2628 children within this parent
            let children = all2628.filter { $0.off >= parent.off && $0.off + $0.size <= pEnd }

            print("Group[\(gi)] @\(parent.off) size=\(parent.size)  children=\(children.count)")

            for (ci, child) in children.enumerated() {
                let cEnd = child.off + child.size
                let hex = (child.off..<cEnd).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
                print("  Child[\(ci)] @\(child.off) size=\(child.size)")
                print("  hex: \(hex)")

                // Parse 0x2628 content: [u32 nameLen][name][three-point section]
                let pos = child.off
                guard pos + 4 < data.count else { continue }
                let nl = Int(UInt32(data[pos]) | UInt32(data[pos+1]) << 8 | UInt32(data[pos+2]) << 16 | UInt32(data[pos+3]) << 24)
                guard nl > 0, nl <= 512, pos + 4 + nl <= data.count else {
                    print("  → invalid nameLen \(nl)")
                    continue
                }
                let name = String(bytes: data[pos+4..<pos+4+nl], encoding: .utf8) ?? "<non-utf8>"
                print("  → name: '\(name)' (nameLen=\(nl))")

                let tp = pos + 4 + nl
                guard tp + 5 <= data.count else { print("  → too short for three-point"); continue }
                let byte0 = data[tp]
                let byte1 = data[tp+1]; let nSrcOff = Int((byte1 & 0xf0) >> 4)
                let byte2 = data[tp+2]; let nLength  = Int((byte2 & 0xf0) >> 4)
                let byte3 = data[tp+3]; let nStart   = Int((byte3 & 0xf0) >> 4)
                let byte4 = data[tp+4]
                print("  → three-point bytes: \(String(format:"%02x %02x %02x %02x %02x", byte0,byte1,byte2,byte3,byte4))")
                print("  → nSrcOff=\(nSrcOff) nLength=\(nLength) nStart=\(nStart)")

                guard tp + 5 + nSrcOff + nLength + nStart <= data.count else { print("  → values overflow"); continue }
                var vp = tp + 5
                let srcOff    = readLE(data, at: vp, count: nSrcOff); vp += nSrcOff
                let lengthVal = readLE(data, at: vp, count: nLength);  vp += nLength
                let startVal  = readLE(data, at: vp, count: nStart)
                print("  → srcOff=\(srcOff) length=\(lengthVal) start=\(startVal)")

                // File index: u16 LE at last 2 bytes of block content
                if child.size >= 2 {
                    let fileIdx = Int(UInt16(data[child.off + child.size - 2]) | UInt16(data[child.off + child.size - 1]) << 8)
                    print("  → fileIdx=\(fileIdx) (last 2 bytes)")
                }

                // Also show ALL bytes after the three-point section (before last 2)
                let dataStart = tp + 5 + nSrcOff + nLength + nStart
                let dataEnd = child.off + child.size - 2
                if dataStart < dataEnd {
                    let tail = (dataStart..<dataEnd).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
                    print("  → extra bytes [\(dataEnd - dataStart)]: \(tail)")
                }
                print()
            }

            // Also show the full raw bytes of the parent block (first 128)
            let rawEnd = min(parent.off + parent.size, parent.off + 128)
            let rawHex = (parent.off..<rawEnd).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print("  parent raw (first 128): \(rawHex)")
            print()
        }

        // Summary: how many 0x262b parents have multiple 0x2628 children?
        print("=== Summary ===")
        var multiples = 0
        for parent in parents262b {
            let pEnd = parent.off + parent.size
            let count = all2628.filter { $0.off >= parent.off && $0.off + $0.size <= pEnd }.count
            if count > 1 { multiples += 1 }
        }
        print("Parents with >1 child: \(multiples) / \(parents262b.count)")

        // Show the 0x104f group placements to cross-reference clipIdx with compound pool
        let all104f = blocks.filter { $0.ct == 0x104f }
        let groupPlacements = all104f.filter { b in
            b.off + 19 <= data.count && data[b.off + 18] == 0x01
        }
        print("\n=== 0x104f group placements (byte18==0x01): \(groupPlacements.count) ===")
        for (i, b) in groupPlacements.prefix(20).enumerated() {
            guard b.off + 11 <= data.count else { continue }
            let clipIdx = Int(UInt16(data[b.off+2]) | UInt16(data[b.off+3]) << 8)
            let timeline = UInt32(data[b.off+7]) | UInt32(data[b.off+8]) << 8 | UInt32(data[b.off+9]) << 16 | UInt32(data[b.off+10]) << 24
            let byte0 = data[b.off]
            print("  [\(i)] clipIdx=\(clipIdx) timeline=\(timeline) muted=\(byte0==1)")
        }
    }

    static func readLE(_ data: Data, at offset: Int, count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        var v: UInt64 = 0
        for i in 0..<count { v |= UInt64(data[offset + i]) << (i * 8) }
        return v
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

DumpCompoundGroups.run()
