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
    let startSample: Int64      // source start (not timeline position — used for lookup only)
    let sourceOffset: Int64     // offset into the source audio file (samples)
    let lengthSamples: Int64    // clip duration (samples)
    let audioFileIndex: Int     // index into the AudioFileEntry list
}

/// A single clip placement on the session timeline (from a 0x104f playlist entry).
struct ClipPlacement {
    let clipIdx: Int        // index into the ClipEntry list (u16 at 0x104f offset+2)
    let timelineSample: Int64   // actual position on timeline (u32 at 0x104f offset+7)
    let trackHint: Int      // raw value from 0x104f that may indicate track (TBD)
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
        //
        // Validate hierarchy: only accept 0x2628 blocks that are contained within a 0x2629
        // parent block. The flat byte-by-byte scanner picks up false positives; containment
        // filtering eliminates them and keeps clip indices stable for the track→clip map.
        let clipParentRanges: [(Int, Int)] = blocks
            .filter { $0.contentType == 0x2629 }
            .map { ($0.dataOffset, $0.dataOffset + $0.dataSize) }

        var results = [ClipEntry]()
        for block in blocks where block.contentType == 0x2628 {
            guard clipParentRanges.contains(where: {
                block.dataOffset >= $0.0 && block.dataOffset + block.dataSize <= $0.1
            }) else { continue }
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

            // Timeline position comes from the playlist (0x104f), not the clip bin.
            // Only filter on length — zero-length and implausibly large are invalid.
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

    // MARK: Playlist structure dump (for track assignment research)
    // Dumps all block types inside the first non-empty 0x1054 in order,
    // highlighting 0x1052 (likely per-track dividers) and 0x1050 clip entries.
    static func dumpPlaylistEntries(blocks: [PTXBlock], data: Data, bigEndian: Bool) {
        guard let playlist = blocks.filter({ $0.contentType == 0x1054 })
                                   .sorted(by: { $0.dataOffset < $1.dataOffset })
                                   .first(where: { b in
                                       blocks.contains { $0.contentType == 0x104f &&
                                           $0.dataOffset >= b.dataOffset &&
                                           $0.dataOffset + $0.dataSize <= b.dataOffset + b.dataSize }
                                   }) else { return }

        let rangeStart = playlist.dataOffset
        let rangeEnd   = playlist.dataOffset + playlist.dataSize
        let inner = blocks.filter {
            $0.dataOffset >= rangeStart && $0.dataOffset + $0.dataSize <= rangeEnd
        }.sorted { $0.dataOffset < $1.dataOffset }

        print("[dumpPlaylist] Inside 0x1054 @ \(rangeStart): \(inner.count) sub-blocks")
        var clipCount = 0
        for b in inner {
            let typeStr = String(format: "0x%04x", b.contentType)
            if b.contentType == 0x1052 {
                let raw = (0..<min(b.dataSize, 16)).map { String(format: "%02x", data[b.dataOffset + $0]) }.joined(separator: " ")
                print("  ── 0x1052 size=\(b.dataSize) [\(raw)]  ← track divider?")
                clipCount = 0
            } else if b.contentType == 0x1050 {
                let pos = b.dataSize >= 20 ? Int(u32(data, at: b.dataOffset + 16, be: bigEndian)) : -1
                let cidx = b.dataSize >= 12 ? Int(u16(data, at: b.dataOffset + 11, be: bigEndian)) : -1
                clipCount += 1
                if clipCount <= 2 {
                    print("    0x1050[\(clipCount)] cidx=\(cidx) pos=\(pos)")
                }
            } else if b.contentType != 0x104f {
                print("  \(typeStr) size=\(b.dataSize)")
            }
        }
    }

    // MARK: Track → Clip Map (via 0x1052 per-track playlist blocks)
    //
    // Within each 0x1054 (global playlist container):
    //   0x1052  per-track section: [u32 nameLen][name bytes][sub-blocks...]
    //     0x1050  one clip placement, contains:
    //       0x104f  clip reference: [skip 2][u16 clipIdx][skip 4][u32 timelinePos...]
    //
    // Tracks appear once per channel (stereo = 2× same name, 5.1 = 6×).
    // We merge channels into one track entry and record the count.

    struct TrackPlaylist {
        var name:         String
        var channelCount: Int
        var placements:   [ClipPlacement]
        var isHidden:     Bool    = false
        var isInactive:   Bool    = false
        var trackTypeCode: UInt16 = 0     // 0=audio, 2=aux, 8=video, 9=VCA, 11=folder
        var folderName:   String? = nil
    }

    // MARK: Track display info (type, hidden, inactive)
    //
    // Each 0x251a sub-block within 0x2519 holds per-track display metadata.
    // Block content layout (all offsets from block dataOffset):
    //   [0-1]              u16 LE track type code:
    //                        0x00 = audio, 0x02 = aux, 0x08 = video,
    //                        0x09 = VCA,   0x0b = folder
    //   [2-5]              u32 LE nameLen
    //   [6 .. 6+nameLen-1] track name (UTF-8)
    //   [6+nameLen]        channel format byte (0=mono, 1=stereo)
    //   [6+nameLen+1..5]   5 zero bytes
    //   [6+nameLen+6..9]   u32 marker = 42
    //   [6+nameLen+10..17] 8-byte UUID
    //   [6+nameLen+18]     display index (0 = hidden for most types, but not video)
    //   ... (9 bytes zeros, repeated marker+UUID, 2 bytes) ...
    //   [6+nameLen+42..50] nested block header (5a 01 00 04 00 00 00 20 44)
    //   [6+nameLen+51..54] nested block content (4 bytes; byte[2]=01 if folder)
    //   [6+nameLen+55]     b0
    //   [6+nameLen+56]     b1
    //   [6+nameLen+57]     b2: 0 = hidden, 1 = visible
    //   [6+nameLen+58]     b3: 0 = inactive, 1 = active

    struct TrackDisplayInfo {
        var hidden:   Set<String>       = []
        var inactive: Set<String>       = []
        var types:    [String: UInt16]  = [:]   // track type code per name
        var folderOf: [String: String]  = [:]   // reserved (not yet decoded)
    }

    static func extractTrackDisplayInfo(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> TrackDisplayInfo {
        guard let b2519 = blocks.first(where: { $0.contentType == 0x2519 }) else { return TrackDisplayInfo() }
        var info = TrackDisplayInfo()

        // Process only 0x251a sub-blocks that live inside 0x2519
        let parentStart = b2519.dataOffset
        let parentEnd   = b2519.dataOffset + b2519.dataSize
        let subBlocks   = blocks.filter {
            $0.contentType == 0x251a &&
            $0.dataOffset  >= parentStart &&
            $0.dataOffset + $0.dataSize <= parentEnd
        }

        for sub in subBlocks {
            let p = sub.dataOffset
            guard p + 6 <= sub.dataOffset + sub.dataSize else { continue }

            let typeCode = UInt16(data[p]) | UInt16(data[p + 1]) << 8

            guard let nl = safeU32(data, at: p + 2, be: false),
                  nl >= 1, nl <= 256 else { continue }
            let nameLen = Int(nl)
            let nameStart = p + 6
            let nameEndPos = nameStart + nameLen
            guard nameEndPos <= sub.dataOffset + sub.dataSize,
                  let name = String(bytes: data[nameStart..<nameEndPos], encoding: .utf8) else { continue }

            info.types[name] = typeCode

            // Flags at fixed offsets from block start
            let b2Offset = p + 63 + nameLen   // visible: 0 = hidden
            let b3Offset = p + 64 + nameLen   // active:  0 = inactive
            guard b3Offset < sub.dataOffset + sub.dataSize else { continue }

            if data[b2Offset] == 0 { info.hidden.insert(name) }
            if data[b3Offset] == 0 { info.inactive.insert(name) }
        }

        let nonAudioTypes = info.types.filter { $0.value != 0 }.map { "\($0.key)=\($0.value)" }.sorted()
        print("[PTXBlockDecoder] Non-audio types: \(nonAudioTypes)")
        print("[PTXBlockDecoder] Hidden:   \(info.hidden.sorted())")
        print("[PTXBlockDecoder] Inactive: \(info.inactive.sorted())")
        return info
    }

    static func buildTrackPlaylists(blocks: [PTXBlock], data: Data, bigEndian: Bool,
                                    displayInfo: TrackDisplayInfo = TrackDisplayInfo()) -> [TrackPlaylist] {
        // Use the first non-empty 0x1054 (main active playlist set)
        guard let container = blocks
            .filter({ $0.contentType == 0x1054 })
            .sorted(by: { $0.dataOffset < $1.dataOffset })
            .first(where: { b in
                blocks.contains {
                    $0.contentType == 0x1052 &&
                    $0.dataOffset >= b.dataOffset &&
                    $0.dataOffset + $0.dataSize <= b.dataOffset + b.dataSize
                }
            }) else { return [] }

        let cStart = container.dataOffset
        let cEnd   = container.dataOffset + container.dataSize

        // Collect 0x1052 blocks in order — each is one channel of one track
        let trackSections = blocks
            .filter {
                $0.contentType == 0x1052 &&
                $0.dataOffset >= cStart &&
                $0.dataOffset + $0.dataSize <= cEnd
            }
            .sorted { $0.dataOffset < $1.dataOffset }

        // Ordered list of (name, placements) preserving first-seen order
        var nameOrder: [String] = []
        var channelCounts: [String: Int] = [:]
        var placementsByName: [String: [ClipPlacement]] = [:]

        for section in trackSections {
            // Read track name: [u32 nameLen][nameBytes]
            guard let nameLen = safeU32(data, at: section.dataOffset, be: false),
                  nameLen >= 1, nameLen <= 256,
                  section.dataOffset + 4 + Int(nameLen) <= data.count else { continue }
            let nameSlice = data[section.dataOffset + 4 ..< section.dataOffset + 4 + Int(nameLen)]
            guard let name = String(bytes: nameSlice, encoding: .utf8) else { continue }

            // Collect placements from 0x104f blocks within this section
            let sStart = section.dataOffset
            let sEnd   = section.dataOffset + section.dataSize
            let refs = blocks.filter {
                $0.contentType == 0x104f &&
                $0.dataOffset >= sStart &&
                $0.dataOffset + $0.dataSize <= sEnd &&
                $0.dataSize >= 11
            }
            let placements: [ClipPlacement] = refs.compactMap { ref in
                let clipIdx  = Int(u16(data, at: ref.dataOffset + 2, be: bigEndian))
                let timeline = Int64(u32(data, at: ref.dataOffset + 7, be: bigEndian))
                guard timeline > 0 else { return nil }
                return ClipPlacement(clipIdx: clipIdx, timelineSample: timeline, trackHint: 0)
            }

            // Merge channels: first occurrence defines the track, duplicates add to channel count
            // Use the first channel's placements (L channel); all channels share the same positions
            if channelCounts[name] == nil {
                nameOrder.append(name)
                placementsByName[name] = placements
                channelCounts[name] = 1
            } else {
                channelCounts[name]! += 1
                // Merge any placements not already present (by timeline position)
                let existingPositions = Set(placementsByName[name]!.map(\.timelineSample))
                let novel = placements.filter { !existingPositions.contains($0.timelineSample) }
                placementsByName[name]!.append(contentsOf: novel)
            }
        }

        return nameOrder.map { name in
            TrackPlaylist(
                name: name,
                channelCount: channelCounts[name] ?? 1,
                placements: placementsByName[name] ?? [],
                isHidden: displayInfo.hidden.contains(name),
                isInactive: displayInfo.inactive.contains(name),
                trackTypeCode: displayInfo.types[name] ?? 0,
                folderName: displayInfo.folderOf[name]
            )
        }
    }

    // MARK: Session Parameters
    //
    // Block 0x1001 (per-audio-file descriptor) layout:
    //   [0-3]  sample rate LE32 (e.g. 0x0000BB80 = 48000)
    //   [4]    channel count (1=mono, 2=stereo)
    //   [5]    bit depth as raw value (e.g. 0x18 = 24)
    //   [6-9]  file length in samples LE32
    //
    // Block 0x1028 (most-recently-used descriptor) layout:
    //   [0]    unknown byte
    //   [1]    bit depth (raw value, same as 0x1001[5])
    //   [2-5]  sample rate LE32
    //   [6-10] 5 padding bytes
    //   [11]   flag byte
    //   [12-15] path component count N (LE32)
    //   [16..] N path strings, each as [LE32 len][UTF-8 bytes]
    //   After N strings:
    //     [+0..+4]  5 zero bytes
    //     [+5..+7]  3 bytes (0x02 0x02 0x00)
    //     [+8]      flag byte (0x01)
    //     [+9]      TC frame rate as raw integer (e.g. 0x18 = 24fps)
    //     [+10..+13] session start in frames LE32

    struct SessionParams {
        var sampleRate:   Int    = 0     // e.g. 48000
        var bitDepth:     Int    = 0     // e.g. 24
        var tcFrameRate:  Int    = 0     // e.g. 24 (frames per second, integer)
        var sessionStartFrames: Int64 = 0  // session start time in frames
    }

    static func extractSessionParams(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> SessionParams {
        var params = SessionParams()

        // Sample rate + bit depth from first 0x1001 block
        if let b = blocks.first(where: { $0.contentType == 0x1001 }), b.dataSize >= 6 {
            let p = b.dataOffset
            let sr = Int(u32(data, at: p, be: false))
            let bd = Int(data[p + 5])
            if sr >= 8000 && sr <= 384000 { params.sampleRate = sr }
            if bd == 16 || bd == 24 || bd == 32 { params.bitDepth = bd }
        }

        // TC frame rate + session start from 0x1028 block
        if let b = blocks.first(where: { $0.contentType == 0x1028 }), b.dataSize >= 16 {
            let p = b.dataOffset
            // Read path component count at bytes[12-15]
            guard let componentCount = safeU32(data, at: p + 12, be: false),
                  componentCount <= 20 else { return params }
            // Skip N path components
            var pos = p + 16
            for _ in 0..<Int(componentCount) {
                guard let len = safeU32(data, at: pos, be: false),
                      len <= 512,
                      pos + 4 + Int(len) <= b.dataOffset + b.dataSize else { break }
                pos += 4 + Int(len)
            }
            // Tail: 5 zeros + 3 bytes + 1 byte flag + 1 byte TC rate + 4 bytes session start
            let tcOff = pos + 5 + 3 + 1   // skip 5 zeros, 02 02 00, and 01 flag
            let startOff = tcOff + 1
            guard startOff + 4 <= b.dataOffset + b.dataSize else { return params }
            let fps = Int(data[tcOff])
            let startFrames = Int64(u32(data, at: startOff, be: false))
            if fps >= 23 && fps <= 60 { params.tcFrameRate = fps }
            params.sessionStartFrames = startFrames
        }

        return params
    }

    // Keep old signature for compatibility — now unused internally but may be called from parser
    static func buildTrackClipMap(
        blocks: [PTXBlock],
        data: Data,
        bigEndian: Bool,
        trackCount: Int
    ) -> [[ClipPlacement]] {
        return []   // replaced by buildTrackPlaylists
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
