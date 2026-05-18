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
    let name: String        // base name without extension (e.g. "Kick_01")
    let fileName: String    // full name with extension (e.g. "Kick_01.wav")
    let folderName: String  // containing subfolder name from FOLDER_MARKER (e.g. "Audio Files")
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
    var isHidden: Bool = false    // true if byte[35]==0x01: sync/dialog ref, not shown on timeline
    var isMuted:  Bool = false    // true if byte[0]==0x01 in 0x104f content
    var isGroup: Bool = false    // true if byte[18]==0x01 (compound group; may or may not be muted)
    var groupName: String? = nil // compound clip name ("1 src.grp.L") when isGroup==true
    var groupLength: Int64? = nil // compound clip length in samples when isGroup==true
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
        // Use unsafe buffer pointer access (much faster than Data subscript for large files)
        decoded.withUnsafeMutableBytes { outBuf in
            raw.withUnsafeBytes { inBuf in
                let out = outBuf.bindMemory(to: UInt8.self).baseAddress!
                let inp = inBuf.bindMemory(to: UInt8.self).baseAddress!
                let n = raw.count
                if fileType == 0x05 {
                    // PT 10+: XOR key changes every 4096 bytes.
                    // First 4096 bytes use table[0]=0 (no-op), skip them.
                    let chunkSize = 4096
                    for chunk in stride(from: chunkSize, to: n, by: chunkSize) {
                        let xorByte = table[(chunk >> 12) & 0xff]
                        guard xorByte != 0 else { continue }
                        let end = min(chunk + chunkSize, n)
                        for i in chunk..<end { out[i] = inp[i] ^ xorByte }
                    }
                } else {
                    // PT 5–9: table indexed per-byte (256-byte repeating pattern)
                    for i in 0..<n { out[i] = inp[i] ^ table[i & 0xff] }
                }
            }
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
    //   [9-byte header: u32 unknown, u8 version, u32 entry count]
    //   Repeated entries — each: [u32 nameLen][name bytes][4-byte typeField][5-byte trail]
    //
    //   FOLDER_MARKER:   typeField = 0x00000000, trail[0] = 0x02
    //   AUDIO_FILE:      typeField in { "EVAW","WAVE","AIFF","FFIA",… }
    //   PATH_COMPONENT:  trail[0] = 0x01 (ignored for now)

    private static let audioTypeTags: Set<String> = ["WAVE", "AIFF", "EVAW", "FFIA"]

    static func extractAudioFiles(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> [AudioFileEntry] {
        var results = [AudioFileEntry]()

        for block in blocks where block.contentType == 0x103a {
            var pos = block.dataOffset + 9   // skip 9-byte block header
            let end = block.dataOffset + block.dataSize
            var currentFolderName = "Audio Files"

            while pos + 4 <= end {
                guard let nl = safeU32(data, at: pos, be: bigEndian),
                      nl >= 1, nl <= 512,
                      pos + 4 + Int(nl) + 9 <= end else { break }

                let nameSlice = data[(pos + 4) ..< (pos + 4 + Int(nl))]
                let name = String(bytes: nameSlice, encoding: .utf8) ?? ""

                let typeStart = pos + 4 + Int(nl)
                let typeBytes = data[typeStart ..< typeStart + 4]
                let tag = String(bytes: typeBytes, encoding: .ascii) ?? ""
                let trail0 = data[typeStart + 4]

                if Self.audioTypeTags.contains(tag) {
                    if !name.isEmpty {
                        let baseName = (name as NSString).deletingPathExtension
                        results.append(AudioFileEntry(
                            index: results.count,
                            name: baseName,
                            fileName: name,
                            folderName: currentFolderName
                        ))
                    }
                } else if trail0 == 0x02 && typeBytes.allSatisfy({ $0 == 0 }) {
                    if !name.isEmpty { currentFolderName = name }
                }

                pos += 4 + Int(nl) + 9
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

    static func extractClips(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> [ClipEntry?] {
        // Each 0x2629 block is a clip-pool container; its ordinal position (sorted by file offset)
        // is the clipIdx referenced in 0x104f playlist entries.  We must preserve that mapping
        // exactly — do NOT build a compact array by skipping entries, or every subsequent clipIdx
        // will point to the wrong name.
        //
        // Strategy: sort the 0x2629 parents, assign each an index, then for every 0x2628 child
        // found within a parent, store the parsed ClipEntry at that parent's index.  The result
        // is a sparse [ClipEntry?] where nil means "no valid clip at this pool position".
        //
        // 0x2628 block format: [u32 nameLen][name bytes]
        //   Three-point section immediately after name:
        //     [+0] leading byte
        //     [+1] HIGH nibble = byte count for sourceOffset (0 = value is zero)
        //     [+2] HIGH nibble = byte count for length
        //     [+3] HIGH nibble = byte count for start (source start position)
        //     [+4] skip
        //     [+5..] sourceOffset (LE), length (LE), start (LE)
        //   File index: u16 LE at last 2 bytes of block content

        // Sort 0x2629 parents by position — index in this array == clipIdx
        let parentBlocks = blocks
            .filter { $0.contentType == 0x2629 }
            .sorted { $0.dataOffset < $1.dataOffset }
        let parentRanges = parentBlocks.map { ($0.dataOffset, $0.dataOffset + $0.dataSize) }

        // Binary search: which parent (by index) contains a given 0x2628 block?
        func parentIndex(of block: PTXBlock) -> Int? {
            var lo = 0, hi = parentRanges.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if parentRanges[mid].0 <= block.dataOffset { lo = mid + 1 } else { hi = mid }
            }
            let idx = lo - 1
            guard idx >= 0 else { return nil }
            return block.dataOffset + block.dataSize <= parentRanges[idx].1 ? idx : nil
        }

        var poolByIndex: [Int: ClipEntry] = [:]

        for block in blocks where block.contentType == 0x2628 {
            guard let pIdx = parentIndex(of: block) else { continue }
            guard poolByIndex[pIdx] == nil else { continue }   // first child per parent wins

            let pos = block.dataOffset
            guard let nl = safeU32(data, at: pos, be: bigEndian),
                  nl >= 1, nl <= 512,
                  pos + 4 + Int(nl) <= data.count else { continue }
            let nameSlice = data[pos+4 ..< pos+4+Int(nl)]
            // Accept any valid UTF-8 (including non-ASCII: accented chars, Unicode filenames)
            guard let name = String(bytes: nameSlice, encoding: .utf8), !name.isEmpty else { continue }

            let tp = pos + 4 + Int(nl)
            guard tp + 5 <= data.count else { continue }

            // HIGH nibble gives byte count; 0 means value is 0 (zero bytes consumed)
            let nSrcOff = Int((data[tp + 1] & 0xf0) >> 4)
            let nLength = Int((data[tp + 2] & 0xf0) >> 4)
            let nStart  = Int((data[tp + 3] & 0xf0) >> 4)

            guard nSrcOff <= 8, nLength <= 8, nStart <= 8,
                  tp + 5 + nSrcOff + nLength + nStart <= data.count else { continue }

            var vp = tp + 5
            let srcOff    = readLE(data, at: vp, count: nSrcOff); vp += nSrcOff
            let lengthVal = readLE(data, at: vp, count: nLength);  vp += nLength
            let startVal  = readLE(data, at: vp, count: nStart)

            // File index: u16 LE in the last 2 bytes of block content
            let fileIdx = block.dataSize >= 2
                ? Int(u16(data, at: block.dataOffset + block.dataSize - 2, be: false))
                : 0

            guard lengthVal < 10_000_000_000 else { continue }

            poolByIndex[pIdx] = ClipEntry(
                name: name,
                startSample: Int64(bitPattern: startVal),
                sourceOffset: Int64(bitPattern: srcOff),
                lengthSamples: Int64(bitPattern: lengthVal),
                audioFileIndex: fileIdx
            )
        }

        return (0..<parentBlocks.count).map { poolByIndex[$0] }
    }

    // MARK: Video Clips
    //
    // Video timeline placements live in the 0x1055 container (parallel to audio's 0x1054),
    // in 0x104f clip-reference blocks (same type as audio).
    //
    // Video 0x104f content layout (all offsets from block dataOffset):
    //   [0]      size byte (0x10)
    //   [1]      zero
    //   [2]      zero
    //   [3]      clip index (u8, into the video clip pool built from 0x262d→0x2628)
    //   [4-6]    zeros
    //   [7-10]   timeline position in FRAMES (LE32) — convert to samples via ×(sr/fps)
    //   [11+]    further fields (ignored)
    //
    // The video clip pool (0x262d→0x2628) provides clip names and lengths (also in frames).
    // Pool entries are ordered by file occurrence; clip index 0 = first pool entry, etc.

    static func extractVideoClips(blocks: [PTXBlock], data: Data, bigEndian: Bool,
                                   sampleRate: Int, frameRate: Int) -> [PTXClip] {
        guard sampleRate > 0, frameRate > 0 else { return [] }
        let samplesPerFrame = Int64(sampleRate) / Int64(frameRate)

        // Build video clip pool: name + length (frames→samples) from 0x262d→0x2628.
        // Do NOT deduplicate — pool index must match the clip index stored in 0x104f.
        let parentRanges: [(Int, Int)] = blocks
            .filter { $0.contentType == 0x262d }
            .map { ($0.dataOffset, $0.dataOffset + $0.dataSize) }
            .sorted { $0.0 < $1.0 }

        func isInVideoPool(_ block: PTXBlock) -> Bool {
            var lo = 0, hi = parentRanges.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if parentRanges[mid].0 <= block.dataOffset { lo = mid + 1 } else { hi = mid }
            }
            let idx = lo - 1
            guard idx >= 0 else { return false }
            return block.dataOffset + block.dataSize <= parentRanges[idx].1
        }

        struct VideoPoolEntry { let name: String; let lengthSamples: Int64 }
        var videoPool = [VideoPoolEntry]()

        for block in blocks where block.contentType == 0x2628 {
            guard isInVideoPool(block) else { continue }
            let pos = block.dataOffset
            guard let nl = safeU32(data, at: pos, be: bigEndian),
                  nl >= 1, nl <= 512,
                  pos + 4 + Int(nl) <= data.count else { continue }
            let nameSlice = data[pos+4 ..< pos+4+Int(nl)]
            guard nameSlice.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                  let name = String(bytes: nameSlice, encoding: .utf8) else { continue }

            var lengthSamples: Int64 = 0
            let tp = pos + 4 + Int(nl)
            if tp + 5 <= data.count {
                let nSrcOff = Int((data[tp + 1] & 0xf0) >> 4)
                let nLength = Int((data[tp + 2] & 0xf0) >> 4)
                if nSrcOff <= 5, nLength <= 5, tp + 5 + nSrcOff + nLength <= data.count {
                    let vp = tp + 5 + nSrcOff
                    let lf = readLE(data, at: vp, count: nLength)
                    if lf > 0, lf < 500_000_000 {
                        lengthSamples = Int64(bitPattern: lf) * samplesPerFrame
                    }
                }
            }
            videoPool.append(VideoPoolEntry(name: name, lengthSamples: lengthSamples))
        }

        print("[PTXBlockDecoder] Video clip pool: \(videoPool.count) entries (first 5: \(videoPool.prefix(5).map(\.name)))")

        // Find the 0x1055 video playlist container and collect 0x104f timeline refs within it.
        guard let container = blocks
            .filter({ $0.contentType == 0x1055 })
            .sorted(by: { $0.dataOffset < $1.dataOffset })
            .first else { return [] }

        let cStart = container.dataOffset
        let cEnd   = container.dataOffset + container.dataSize

        // All 0x104f refs pre-sorted; binary-search to the start of the 0x1055 range.
        let sortedRefs = blocks
            .filter { $0.contentType == 0x104f && $0.dataSize >= 11 }
            .sorted { $0.dataOffset < $1.dataOffset }

        var lo = 0, hi = sortedRefs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedRefs[mid].dataOffset < cStart { lo = mid + 1 } else { hi = mid }
        }

        var results = [PTXClip]()
        var j = lo
        while j < sortedRefs.count {
            let ref = sortedRefs[j]; j += 1
            guard ref.dataOffset < cEnd else { break }
            guard ref.dataOffset + ref.dataSize <= cEnd else { continue }

            // Clip index: single byte at offset+3.
            // Timeline position: LE32 at offset+7, in frames.
            let clipIdx       = Int(data[ref.dataOffset + 3])
            let timelineFrames = Int64(u32(data, at: ref.dataOffset + 7, be: false))
            guard timelineFrames > 0 else { continue }

            let entry = clipIdx < videoPool.count ? videoPool[clipIdx] : nil
            results.append(PTXClip(
                name:          entry?.name ?? "Video Clip \(clipIdx)",
                startSample:   timelineFrames * samplesPerFrame,
                lengthSamples: entry?.lengthSamples ?? 0
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

    /// Builds the compound clip pool from 0x262b parent blocks and their 0x2628 children.
    /// 0x262b blocks are the compound/group clip pool parents (analogous to 0x2629 for audio).
    /// Each 0x2628 child uses the same encoding as audio clip entries.
    /// Returns sparse array indexed by file-order position of the 0x262b parent.
    static func extractCompoundClips(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> [(name: String, lengthSamples: Int64)?] {
        let parentBlocks = blocks
            .filter { $0.contentType == 0x262b }
            .sorted { $0.dataOffset < $1.dataOffset }
        let parentRanges = parentBlocks.map { ($0.dataOffset, $0.dataOffset + $0.dataSize) }

        func parentIndex(of block: PTXBlock) -> Int? {
            var lo = 0, hi = parentRanges.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if parentRanges[mid].0 <= block.dataOffset { lo = mid + 1 } else { hi = mid }
            }
            let idx = lo - 1
            guard idx >= 0, block.dataOffset + block.dataSize <= parentRanges[idx].1 else { return nil }
            return idx
        }

        var poolByIndex: [Int: (name: String, lengthSamples: Int64)] = [:]
        for block in blocks where block.contentType == 0x2628 {
            guard let pIdx = parentIndex(of: block) else { continue }
            guard poolByIndex[pIdx] == nil else { continue }

            let pos = block.dataOffset
            guard let nl = safeU32(data, at: pos, be: bigEndian),
                  nl >= 1, nl <= 512,
                  pos + 4 + Int(nl) <= data.count else { continue }
            // Accept any valid UTF-8 (including non-ASCII filenames)
            guard let name = String(bytes: data[pos+4 ..< pos+4+Int(nl)], encoding: .utf8),
                  !name.isEmpty else { continue }

            let tp = pos + 4 + Int(nl)
            guard tp + 5 <= data.count else { continue }
            let nLength = Int((data[tp + 2] & 0xf0) >> 4)
            let nSrcOff = Int((data[tp + 1] & 0xf0) >> 4)
            let nStart  = Int((data[tp + 3] & 0xf0) >> 4)
            guard nSrcOff <= 8, nLength <= 8, nStart <= 8,
                  tp + 5 + nSrcOff + nLength + nStart <= data.count else { continue }
            var vp = tp + 5
            vp += nSrcOff  // skip sourceOffset
            let lengthVal = readLE(data, at: vp, count: nLength)
            guard lengthVal > 0, lengthVal < 10_000_000_000 else { continue }

            poolByIndex[pIdx] = (name: name, lengthSamples: Int64(bitPattern: lengthVal))
        }

        return (0..<parentBlocks.count).map { poolByIndex[$0] }
    }

    static func buildTrackPlaylists(blocks: [PTXBlock], data: Data, bigEndian: Bool,
                                    displayInfo: TrackDisplayInfo = TrackDisplayInfo()) -> [TrackPlaylist] {
        // Build compound clip pool: poolIndex → (name, lengthSamples)
        // Used for group placements (byte0==0x01); pool is 0x262b→0x2628.
        let compoundPool = extractCompoundClips(blocks: blocks, data: data, bigEndian: bigEndian)

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

        // Build sorted 0x1050 parent ranges within the container.
        // Every real 0x104f lives inside a 0x1050 clip-placement wrapper; any 0x104f block
        // found by the flat scanner that is NOT inside a 0x1050 is a false positive produced
        // by the scanner reading block-like bytes within data payloads.
        let sorted1050 = blocks
            .filter { $0.contentType == 0x1050 && $0.dataOffset >= cStart && $0.dataOffset + $0.dataSize <= cEnd }
            .sorted { $0.dataOffset < $1.dataOffset }
        let ranges1050 = sorted1050.map { ($0.dataOffset, $0.dataOffset + $0.dataSize) }

        // Returns the 0x1050 parent of ref, or nil if no valid parent (false positive).
        func parent1050(of ref: PTXBlock) -> PTXBlock? {
            var lo = 0, hi = ranges1050.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ranges1050[mid].0 <= ref.dataOffset { lo = mid + 1 } else { hi = mid }
            }
            let idx = lo - 1
            guard idx >= 0,
                  ref.dataOffset + ref.dataSize <= ranges1050[idx].1 else { return nil }
            return sorted1050[idx]
        }

        // Pre-sort 0x104f blocks by offset once (they're already in order but make it explicit).
        // This allows O(log n) binary search per track section instead of O(n) linear filter.
        let sortedRefs = blocks
            .filter { $0.contentType == 0x104f && $0.dataSize >= 11 }
            .sorted { $0.dataOffset < $1.dataOffset }

        for section in trackSections {
            // Read track name: [u32 nameLen][nameBytes]
            guard let nameLen = safeU32(data, at: section.dataOffset, be: false),
                  nameLen >= 1, nameLen <= 256,
                  section.dataOffset + 4 + Int(nameLen) <= data.count else { continue }
            let nameSlice = data[section.dataOffset + 4 ..< section.dataOffset + 4 + Int(nameLen)]
            guard let name = String(bytes: nameSlice, encoding: .utf8) else { continue }

            // Collect placements from 0x104f blocks within this section using binary search
            let sStart = section.dataOffset
            let sEnd   = section.dataOffset + section.dataSize
            // Find first ref >= sStart
            var lo = 0, hi = sortedRefs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sortedRefs[mid].dataOffset < sStart { lo = mid + 1 } else { hi = mid }
            }
            var refs: [PTXBlock] = []
            var j = lo
            while j < sortedRefs.count && sortedRefs[j].dataOffset >= sStart {
                let r = sortedRefs[j]
                if r.dataOffset + r.dataSize <= sEnd { refs.append(r) } else { break }
                j += 1
            }
            let placements: [ClipPlacement] = refs.compactMap { ref in
                guard parent1050(of: ref) != nil else { return nil }  // reject false positives
                // 0x104f byte[0]: 0x01 = muted clip (individual audio or compound group)
                // 0x104f byte[18]: 0x01 = compound group (uses compound pool for name/length)
                //                  0x00 = muted individual audio clip (uses audio pool)
                // 0x104f byte[35]: 0x00 = visible on timeline, 0x01 = hidden dialog/sync ref
                let byte0   = ref.dataSize >= 1  ? data[ref.dataOffset]      : 0x00
                let byte18  = ref.dataSize >= 19 ? data[ref.dataOffset + 18] : 0x00
                let isMuted  = byte0 == 0x01
                let isGroup  = byte18 == 0x01              // compound group → compound pool (may be muted or unmuted)
                let isHidden = ref.dataSize >= 36 && data[ref.dataOffset + 35] == 0x01
                let clipIdx  = Int(u16(data, at: ref.dataOffset + 2, be: bigEndian))
                let timeline = Int64(u32(data, at: ref.dataOffset + 7, be: bigEndian))
                guard timeline > 0 else { return nil }
                let compoundEntry = isGroup && clipIdx < compoundPool.count ? compoundPool[clipIdx] : nil
                let groupName   = compoundEntry?.name
                let groupLength = compoundEntry?.lengthSamples
                return ClipPlacement(clipIdx: clipIdx, timelineSample: timeline, trackHint: 0,
                                     isHidden: isHidden, isMuted: isMuted, isGroup: isGroup,
                                     groupName: groupName, groupLength: groupLength)
            }

            // Only the FIRST 0x1052 section for each track name is the active playlist.
            // Subsequent sections are alternate playlists (created during loop recording /
            // comping) — they share the same track name but contain different clip sets.
            // Including their "novel" positions would produce ghost clips (positions that
            // exist in alternates but not on the active timeline).
            // For stereo tracks the R-channel section follows L and has the same positions,
            // so skipping it is also correct (no information lost).
            if channelCounts[name] == nil {
                nameOrder.append(name)
                placementsByName[name] = placements
                channelCounts[name] = 1
            } else {
                channelCounts[name]! += 1
                // Ignore subsequent sections — do not add novel positions from alternates.
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
        var tcFrameRate:  Int    = 0     // nominal fps integer (24 for 23.976, 30 for 29.97)
        var tcFormatString: String = "" // human-readable TC format, e.g. "23.976", "29.97 DF"
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
            // Tail: 5 zeros + 3 bytes (02 02 00) + 1 byte TC enum + 1 byte nominal fps + 4 bytes session start
            // TC enum: 0=23.976, 1=24, 2=25, 3=29.97DF, 4=29.97NDF, 5=30DF, 6=30NDF,
            //          7=47.952, 8=48, 9=50, 10=59.94DF, 11=59.94NDF, 12=60
            let enumOff  = pos + 5 + 3          // skip 5 zeros and 02 02 00
            let nomOff   = enumOff + 1           // nominal fps raw int (24, 25, 30 …)
            let startOff = enumOff + 2           // session start in frames LE32
            guard startOff + 4 <= b.dataOffset + b.dataSize else { return params }
            let tcEnum = Int(data[enumOff])
            let nomFps = Int(data[nomOff])
            let tcFormats = ["23.976","24","25","29.97 DF","29.97","30 DF","30",
                             "47.952","48","50","59.94 DF","59.94","60"]
            if tcEnum >= 0 && tcEnum < tcFormats.count {
                params.tcFormatString = tcFormats[tcEnum]
            }
            if nomFps >= 23 && nomFps <= 60 { params.tcFrameRate = nomFps }
            params.sessionStartFrames = Int64(u32(data, at: startOff, be: false))
        }

        return params
    }

    // MARK: Plugin Names
    //
    // Block 0x1017 layout (content starts at dataOffset):
    //   [0]      type byte: 0x03/0x04 = real plugin entry, 0xff = placeholder (skip)
    //   [1-4]    u32 LE display name length (nl)
    //   [5..5+nl-1]  display name (UTF-8)
    //   [5+nl..5+nl+11]  12 bytes of AAX type codes (three 4-byte OSType codes)
    //   [5+nl+12..5+nl+15]  4 bytes flags
    //   [5+nl+16..5+nl+18]  3 bytes
    //   [5+nl+19..5+nl+22]  u32 LE second string length
    //   [5+nl+23..]  bundle ID or variant name
    //
    // Multiple blocks may carry the same display name (mono/stereo variants). Deduplicate.

    static func extractPlugins(blocks: [PTXBlock], data: Data) -> [String] {
        var seen = Set<String>()
        var result = [String]()
        for block in blocks where block.contentType == 0x1017 {
            let p = block.dataOffset
            guard block.dataSize >= 5 else { continue }
            let typeByte = data[p]
            guard typeByte != 0xff else { continue }
            guard let nl = safeU32(data, at: p + 1, be: false),
                  nl >= 1, nl <= 512,
                  p + 5 + Int(nl) <= block.dataOffset + block.dataSize else { continue }
            let nameSlice = data[(p + 5) ..< (p + 5 + Int(nl))]
            guard let name = String(bytes: nameSlice, encoding: .utf8),
                  !name.isEmpty else { continue }
            if seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }

    // MARK: Per-track Plugin Extraction
    //
    // Each track has a 0x102d "mixer strip" block (keyed by track name) immediately followed
    // by a 0x2627 block containing the full plugin preset state for every insert on that track.
    //
    // The 0x2627 block embeds AAX OSType codes at the start of each plugin's state record.
    // These codes are stored big-endian in 0x2627, and byte-reversed in the 0x1017 global
    // registry. We build a map: (reversed ot0 + reversed ot1) → display name, then slide
    // through each 0x2627 block matching any 8-byte window against the map.
    //
    // Returns: trackName → ordered list of plugin display names (insertion order, deduplicated)

    static func extractTrackPlugins(blocks: [PTXBlock], data: Data) -> [String: [String]] {
        let sorted = blocks.sorted { $0.dataOffset < $1.dataOffset }

        // Build (manufacturer+product 8-char key) → display name from 0x1017 blocks
        var keyToPlugin: [String: String] = [:]
        for b in sorted where b.contentType == 0x1017 {
            let p = b.dataOffset
            guard b.dataSize >= 5, data[p] != 0xff else { continue }
            guard let nl = safeU32(data, at: p + 1, be: false),
                  nl >= 1, nl <= 512,
                  p + 5 + Int(nl) + 8 <= b.dataOffset + b.dataSize else { continue }
            guard let name = String(bytes: data[(p+5)..<(p+5+Int(nl))], encoding: .utf8),
                  !name.isEmpty else { continue }
            // OSType bytes in 0x1017 are stored reversed; reverse them back to the canonical form
            let base = p + 5 + Int(nl)
            let ot0 = String(bytes: data[base..<base+4].reversed(), encoding: .utf8) ?? ""
            let ot1 = String(bytes: data[base+4..<base+8].reversed(), encoding: .utf8) ?? ""
            let key = ot0 + ot1
            if key.count == 8 { keyToPlugin[key] = name }
        }
        guard !keyToPlugin.isEmpty else { return [:] }

        // Collect 0x102d track-ID blocks in file order
        var trackEnds: [(name: String, end: Int)] = []
        for b in sorted where b.contentType == 0x102d {
            let p = b.dataOffset + 9   // past nested 0x2619 block header
            guard let nl = safeU32(data, at: p, be: false),
                  nl >= 1, nl <= 64,
                  p + 4 + Int(nl) <= data.count,
                  let name = String(bytes: data[(p+4)..<(p+4+Int(nl))], encoding: .utf8),
                  !name.isEmpty else { continue }
            trackEnds.append((name: name, end: b.dataOffset + b.dataSize))
        }

        var result: [String: [String]] = [:]
        for (i, tb) in trackEnds.enumerated() {
            // 0x2627 blocks that appear between this 0x102d end and the next one's start
            let ceiling = i + 1 < trackEnds.count ? trackEnds[i + 1].end - 300 : Int.max
            let stateBlocks = sorted.filter {
                $0.contentType == 0x2627 &&
                $0.dataOffset >= tb.end &&
                $0.dataOffset < ceiling
            }
            guard !stateBlocks.isEmpty else { continue }

            var plugins: [String] = []
            var seenKeys = Set<String>()
            for pb in stateBlocks {
                guard pb.dataSize >= 8 else { continue }
                for off in 0 ..< (pb.dataSize - 8) {
                    // Fast check: all 8 bytes must be printable ASCII
                    let base = pb.dataOffset + off
                    guard data[base] >= 0x20, data[base+7] >= 0x20 else { continue }
                    let window = data[base ..< base + 8]
                    guard window.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { continue }
                    if let key = String(bytes: window, encoding: .utf8),
                       let pluginName = keyToPlugin[key],
                       seenKeys.insert(key).inserted {
                        plugins.append(pluginName)
                    }
                }
            }
            if !plugins.isEmpty { result[tb.name] = plugins }
        }
        return result
    }

    // MARK: Memory Locations
    //
    // Block 0x2077 layout (one block per memory location):
    //   [0-1]   u16 LE  memory location number
    //   [2-3]   u16 LE  type/flags (always 0x0903 so far)
    //   [4-5]   u16     unused
    //   [6-9]   u32 LE  name length (nl)
    //   [10..10+nl-1]   name bytes (UTF-8)
    //   [10+nl..10+nl+7]  u64 LE  sample position on timeline

    static func extractMemoryLocations(blocks: [PTXBlock], data: Data) -> [PTXMemoryLocation] {
        var result = [PTXMemoryLocation]()
        for block in blocks where block.contentType == 0x2077 {
            let p = block.dataOffset
            guard block.dataSize >= 18 else { continue }
            guard let nl = safeU32(data, at: p + 6, be: false),
                  nl >= 1, nl <= 256,
                  p + 10 + Int(nl) + 8 <= block.dataOffset + block.dataSize else { continue }
            let number = Int(u16(data, at: p, be: false))
            let nameSlice = data[(p + 10) ..< (p + 10 + Int(nl))]
            guard let name = String(bytes: nameSlice, encoding: .utf8), !name.isEmpty else { continue }
            let samp = Int64(bitPattern: UInt64(u32(data, at: p + 10 + Int(nl),     be: false)) |
                                         (UInt64(u32(data, at: p + 10 + Int(nl) + 4, be: false)) << 32))
            guard samp >= 0 else { continue }
            result.append(PTXMemoryLocation(number: number, name: name, samplePosition: samp))
        }
        // Sort by timeline position (the text export lists them in position order)
        return result.sorted { $0.samplePosition < $1.samplePosition }
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
