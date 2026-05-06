import Foundation

// MARK: - PTX Block Decoder
//
// Decodes the XOR-obfuscated block structure in Pro Tools .ptx files (PT 10+).
// Implements the format documented by Damien Zammit in zamaudio/ptformat.
//
// XOR scheme (PT 10+, format byte 0x05):
//   delta  = genXorDelta(key=data[0x13], mul=11, negative=true)
//   table  = [ (i * delta) & 0xff  for i in 0..<256 ]
//   decoded[i] = raw[i] ^ table[(i >> 12) & 0xff]
//   → first 4096 bytes XOR with table[0]=0 (no-op), encrypted region starts at 0x1000
//
// Block header (9 bytes, anchored by 0x5a marker):
//   [0x5a][blockType: u16][blockSize: u32][contentType: u16]
//   Content follows immediately at offset +9.
//
// Key content types (PT 10+):
//   0x1004  Audio file list (parent)
//   0x103a  Audio file names (child of 0x1004)
//   0x262a  Clip/region list (parent)
//   0x2629  Individual clip/region entry
//   0x1015  Audio track list (parent)
//   0x1014  Individual audio track entry
//   0x1054  Track playlist container
//   0x1050  Playlist entry
//   0x104f  Clip reference within a playlist

// MARK: - Raw structs

struct PTXBlock {
    let contentType: UInt16
    let dataOffset: Int    // byte offset in decoded data where block content begins
    let dataSize: Int      // byte count of block content (excludes 9-byte header)
}

struct AudioFileEntry {
    let index: Int
    let name: String       // base name without extension (e.g. "Kick_01")
}

struct ClipEntry {
    let name: String
    let startSample: Int64      // position on the session timeline (samples)
    let sourceOffset: Int64     // offset into the source audio file (samples)
    let lengthSamples: Int64    // clip duration (samples)
    let audioFileIndex: Int     // index into the AudioFileEntry list
}

struct TrackEntry {
    let index: Int
    let name: String
}

// MARK: - PTXBlockDecoder

final class PTXBlockDecoder {

    // MARK: XOR Decode

    /// XOR-decode a raw PTX file. Returns nil if format is unrecognised.
    static func xorDecode(_ raw: Data) -> Data? {
        guard raw.count > 0x14 else { return nil }
        let fileType = raw[0x12]
        let xorValue = raw[0x13]

        let mul: UInt16
        let negative: Bool
        switch fileType {
        case 0x05: mul = 11;  negative = true    // PT 10+
        case 0x01: mul = 53;  negative = false   // PT 5–9
        default:   return nil
        }

        let delta = genXorDelta(xorValue: xorValue, mul: mul, negative: negative)
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            table[i] = UInt8((UInt16(i) * UInt16(delta)) & 0xff)
        }

        var decoded = raw
        for i in 0..<raw.count {
            let idx = (fileType == 0x05) ? (i >> 12) & 0xff : i & 0xff
            decoded[i] = raw[i] ^ table[idx]
        }
        return decoded
    }

    private static func genXorDelta(xorValue: UInt8, mul: UInt16, negative: Bool) -> UInt8 {
        for i: UInt16 in 0...255 {
            if (i * mul) & 0xff == UInt16(xorValue) {
                return negative ? UInt8(truncatingIfNeeded: 256 &- Int(i)) : UInt8(i)
            }
        }
        return 0
    }

    // MARK: Block Scanning

    /// Scan decoded data for all blocks (flat pass — nested blocks are found too).
    /// Filter by contentType and use dataOffset ranges to reconstruct hierarchy.
    static func scanBlocks(data: Data, bigEndian: Bool) -> [PTXBlock] {
        var blocks = [PTXBlock]()
        var i = 0x1f   // first block begins here
        while i + 9 <= data.count {
            guard data[i] == 0x5a else { i += 1; continue }
            let size = Int(u32(data, at: i + 3, be: bigEndian))
            let ct   = u16(data, at: i + 7, be: bigEndian)
            guard size > 0, size < 50_000_000, i + 9 + size <= data.count else { i += 1; continue }
            blocks.append(PTXBlock(contentType: ct, dataOffset: i + 9, dataSize: size))
            i += 1   // byte-by-byte to catch nested blocks
        }
        return blocks
    }

    // MARK: Endianness

    static func isBigEndian(_ data: Data) -> Bool {
        guard data.count > 0x11 else { return false }
        return data[0x11] != 0
    }

    // MARK: Audio File Names
    //
    // Block 0x103a layout (content starts at dataOffset):
    //   [2-byte skip]
    //   Repeated entries:
    //     [u32 nameLen][name bytes]["WAVE"/"AIFF"/"EVAW"/"FFIA" 4 bytes][9-byte padding]

    static func extractAudioFiles(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> [AudioFileEntry] {
        var results = [AudioFileEntry]()
        for block in blocks where block.contentType == 0x103a {
            var pos = block.dataOffset + 2
            let end = block.dataOffset + block.dataSize
            var idx = 0
            while pos + 4 <= end {
                guard let nl = safeU32(data, at: pos, be: bigEndian),
                      nl >= 1, nl <= 512,
                      pos + 4 + Int(nl) + 13 <= data.count else { break }
                let nameSlice = data[pos+4 ..< pos+4+Int(nl)]
                if nameSlice.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                   let name = String(bytes: nameSlice, encoding: .utf8) {
                    results.append(AudioFileEntry(index: idx, name: name))
                    idx += 1
                }
                pos += 4 + Int(nl) + 4 + 9   // name + type tag + padding
            }
        }
        return results
    }

    // MARK: Clips / Regions
    //
    // Block 0x2629 layout (one clip per block, content starts at dataOffset):
    //   [2-byte skip][u32 nameLen][name bytes]
    //   Three-point section (immediately after name):
    //     [+0] leading byte
    //     [+1] low nibble = byte count for start value (1–5)
    //     [+2] low nibble = byte count for sourceOffset value (1–5)
    //     [+3] low nibble = byte count for length value (1–5)
    //     [+4] (unused nibble)
    //     [+5 ...] start (big-endian, nStart bytes)
    //     [+5+nStart ...] sourceOffset (big-endian, nSrcOff bytes)
    //     [+5+nStart+nSrcOff ...] length (big-endian, nLength bytes)
    //   File index: last 4 bytes of block content

    static func extractClips(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> [ClipEntry] {
        // Use 0x2628 blocks — the inner content blocks found directly by the flat scanner.
        // Format: [u32 nameLen][name]
        //   Three-point section immediately after name:
        //     [+0] leading byte
        //     [+1] HIGH nibble = byte count for sourceOffset (0 = value is zero)
        //     [+2] HIGH nibble = byte count for length
        //     [+3] HIGH nibble = byte count for start (timeline position)
        //     [+4] skip
        //     [+5..] sourceOffset (LE), length (LE), start (LE)
        //   File index: u16 LE at last 2 bytes of block content
        var results = [ClipEntry]()
        for block in blocks where block.contentType == 0x2628 {
            let pos = block.dataOffset
            guard let nl = safeU32(data, at: pos, be: bigEndian),
                  nl >= 1, nl <= 512,
                  pos + 4 + Int(nl) <= data.count else { continue }
            let nameSlice = data[pos+4 ..< pos+4+Int(nl)]
            guard nameSlice.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                  let name = String(bytes: nameSlice, encoding: .utf8) else { continue }

            let tp = pos + 4 + Int(nl)
            guard tp + 5 <= data.count else { continue }

            // HIGH nibble gives byte count; 0 means value is 0 (zero bytes consumed)
            let nSrcOff = Int((data[tp + 1] & 0xf0) >> 4)
            let nLength = Int((data[tp + 2] & 0xf0) >> 4)
            let nStart  = Int((data[tp + 3] & 0xf0) >> 4)

            guard nSrcOff <= 5, nLength <= 5, nStart <= 5,
                  tp + 5 + nSrcOff + nLength + nStart <= data.count else { continue }

            var vp = tp + 5
            let srcOff    = readLE(data, at: vp, count: nSrcOff); vp += nSrcOff
            let lengthVal = readLE(data, at: vp, count: nLength);  vp += nLength
            let startVal  = readLE(data, at: vp, count: nStart)

            // File index: u16 LE in the last 2 bytes of block content
            let fileIdx = block.dataSize >= 2
                ? Int(u16(data, at: block.dataOffset + block.dataSize - 2, be: false))
                : 0

            // Skip whole-file reference clips (no real timeline placement)
            guard startVal > 0 || srcOff > 0 else { continue }
            guard lengthVal > 0, lengthVal < 10_000_000_000 else { continue }

            results.append(ClipEntry(
                name: name,
                startSample: Int64(bitPattern: startVal),
                sourceOffset: Int64(bitPattern: srcOff),
                lengthSamples: Int64(bitPattern: lengthVal),
                audioFileIndex: fileIdx
            ))
        }
        return results
    }

    // MARK: Track Names
    //
    // Block 0x1014 layout:
    //   [2-byte skip][u32 nameLen][name bytes]...

    static func extractTracks(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> [TrackEntry] {
        var results = [TrackEntry]()
        var idx = 0
        for block in blocks where block.contentType == 0x1014 {
            let pos = block.dataOffset + 2
            guard let nl = safeU32(data, at: pos, be: bigEndian),
                  nl >= 1, nl <= 256,
                  pos + 4 + Int(nl) <= data.count else { continue }
            let nameSlice = data[pos+4 ..< pos+4+Int(nl)]
            guard nameSlice.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                  let name = String(bytes: nameSlice, encoding: .utf8) else { continue }
            results.append(TrackEntry(index: idx, name: name))
            idx += 1
        }
        return results
    }

    // MARK: Track → Clip Mapping
    //
    // 0x1054 blocks are track playlist containers (one per track, in track order).
    // 0x104f blocks within each 0x1054 range hold clip references:
    //   [4-byte skip][u32 clipIndex]
    //
    // Returns an array (indexed by track) of clip index arrays.

    static func buildTrackClipMap(
        blocks: [PTXBlock],
        data: Data,
        bigEndian: Bool,
        trackCount: Int
    ) -> [[Int]] {
        let playlists = blocks
            .filter { $0.contentType == 0x1054 }
            .sorted { $0.dataOffset < $1.dataOffset }

        var map = [[Int]](repeating: [], count: max(playlists.count, trackCount))

        for (trackIdx, playlist) in playlists.enumerated() {
            let rangeStart = playlist.dataOffset
            let rangeEnd   = playlist.dataOffset + playlist.dataSize
            let refs = blocks.filter {
                $0.contentType == 0x104f &&
                $0.dataOffset >= rangeStart &&
                $0.dataOffset + $0.dataSize <= rangeEnd &&
                $0.dataSize >= 8
            }
            map[trackIdx] = refs.map { Int(u32(data, at: $0.dataOffset + 4, be: bigEndian)) }
        }
        return map
    }

    // MARK: - Helpers

    static func u16(_ d: Data, at i: Int, be: Bool) -> UInt16 {
        guard i + 2 <= d.count else { return 0 }
        return be
            ? UInt16(d[i]) << 8 | UInt16(d[i+1])
            : UInt16(d[i]) | UInt16(d[i+1]) << 8
    }

    static func u32(_ d: Data, at i: Int, be: Bool) -> UInt32 {
        guard i + 4 <= d.count else { return 0 }
        return be
            ? UInt32(d[i]) << 24 | UInt32(d[i+1]) << 16 | UInt32(d[i+2]) << 8 | UInt32(d[i+3])
            : UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
    }

    private static func safeU32(_ d: Data, at i: Int, be: Bool) -> UInt32? {
        guard i + 4 <= d.count else { return nil }
        return u32(d, at: i, be: be)
    }

    static func readLE(_ d: Data, at i: Int, count: Int) -> UInt64 {
        var v: UInt64 = 0
        for j in 0..<count { v |= UInt64(d[i + j]) << (j * 8) }
        return v
    }
}
