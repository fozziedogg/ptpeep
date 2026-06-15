import Foundation

// Scan a PTX file for blocks that might contain fade or clip-gain data.
// Strategy: dump ALL block types with counts, then show full content of
// any unknown/interesting block types that appear a plausible number of
// times (matching clip counts).  Also show the 0x104f block bytes more
// completely so we can find bytes beyond mute/group/hidden.

struct DumpFadesGain {
    struct Block { let ct: UInt16; let off: Int; let size: Int }

    static func run() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: dump_fades_gain <file.ptx>\n", stderr); exit(1)
        }
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let data = xorDecode(raw) else { fputs("XOR decode failed\n", stderr); exit(1) }
        let blocks = scanBlocks(data)

        // ── 1. Block type summary ─────────────────────────────────────────────
        var typeCounts   = [UInt16: Int]()
        var typeFirstOff = [UInt16: Int]()
        for b in blocks {
            typeCounts[b.ct, default: 0] += 1
            if typeFirstOff[b.ct] == nil { typeFirstOff[b.ct] = b.off }
        }
        print("=== Block type summary ===")
        for ct in typeCounts.keys.sorted() {
            print(String(format: "  0x%04x  count=%-5d  first_off=%d", ct, typeCounts[ct]!, typeFirstOff[ct]!))
        }

        // ── 2. Show ALL bytes of every 0x104f block (clip placement) ─────────
        // We know bytes 0, 18, 35.  Print full hex to find fade/gain bytes.
        let blocks104f = blocks.filter { $0.ct == 0x104f }
        print("\n=== 0x104f blocks (clip placements) — first 10, full content ===")
        for b in blocks104f.prefix(10) {
            let end = b.off + b.size
            let hex = (b.off..<end).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print(String(format: "  @%-6d size=%-4d  %@", b.off, b.size, hex))
        }

        // ── 3. Candidate "fade" block types ───────────────────────────────────
        // Fades in PT are often stored in separate blocks per clip.
        // Look for block types with counts in a similar range to 0x104f.
        let clip104fCount = typeCounts[0x104f] ?? 0
        print("\n=== Block types with count in [\(max(1,clip104fCount/4))..\(clip104fCount*4)] (potential per-clip blocks) ===")
        let candidates: [UInt16] = [
            0x1050, 0x1051, 0x1052, 0x1053, 0x1054, 0x1055,
            0x1060, 0x1061, 0x1070, 0x1080, 0x1090,
            0x2050, 0x2051, 0x2060, 0x2070,
            0x104e, 0x104d, 0x104c,
        ]
        for ct in candidates {
            guard let count = typeCounts[ct] else { continue }
            let firstOff = typeFirstOff[ct]!
            let b = blocks.first(where: { $0.ct == ct })!
            let end = b.off + min(b.size, 48)
            let hex = (b.off..<end).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print(String(format: "  0x%04x count=%-5d  first @%-6d  preview: %@", ct, count, firstOff, hex))
        }

        // ── 4. Show ANY block type we haven't accounted for ───────────────────
        // Known / accounted types (expand as we map them)
        let known: Set<UInt16> = [
            0x0001, 0x0002,                           // header/version
            0x2519, 0x251a, 0x251b, 0x251c,           // track containers
            0x2624, 0x2625, 0x2626, 0x2627, 0x2628,   // compound pools
            0x104f,                                    // clip placements (mapped)
            0x210c,                                    // something we dumped
            0x4420, 0x4421, 0x4422,                   // something we dumped
        ]
        print("\n=== Unknown block types (not in known set) ===")
        for ct in typeCounts.keys.sorted() where !known.contains(ct) {
            let count = typeCounts[ct]!
            let b = blocks.first(where: { $0.ct == ct })!
            let end = b.off + min(b.size, 64)
            let hex = (b.off..<end).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            print(String(format: "  0x%04x count=%-5d  first @%-6d  preview: %@", ct, count, b.off, hex))
        }
    }

    // ── Helpers (identical to other dump scripts) ─────────────────────────────

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

DumpFadesGain.run()
