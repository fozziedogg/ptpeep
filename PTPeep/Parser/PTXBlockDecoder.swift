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

/// One constituent clip inside a compound/group clip.
/// Decoded from the sentinel 0x1052 sections in the second 0x1054 container.
struct ConstituentClip {
    /// When isSubGroup==false: index into the ClipEntry audio pool (0x2629 ordinals).
    /// When isSubGroup==true:  index into the compound pool (0x262b ordinals, == combined-pool index
    ///                         for sessions where compounds precede audio in the combined pool).
    let audioClipIdx: Int
    let relativeOffset: Int64 // samples from the group's own timeline position
    let isSubGroup: Bool      // true = compound sub-group bracket; false = leaf audio clip
    let subGroupName: String  // compound name (non-empty when isSubGroup==true)
    let subGroupLength: Int64 // compound duration in samples (>0 when isSubGroup==true)

    /// Convenience init for audio leaf constituents (isSubGroup=false).
    init(audioClipIdx: Int, relativeOffset: Int64) {
        self.audioClipIdx = audioClipIdx; self.relativeOffset = relativeOffset
        self.isSubGroup = false; self.subGroupName = ""; self.subGroupLength = 0
    }

    /// Init for compound sub-group constituents (isSubGroup=true).
    init(audioClipIdx: Int, relativeOffset: Int64, isSubGroup: Bool, subGroupName: String, subGroupLength: Int64) {
        self.audioClipIdx = audioClipIdx; self.relativeOffset = relativeOffset
        self.isSubGroup = isSubGroup; self.subGroupName = subGroupName; self.subGroupLength = subGroupLength
    }
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
    /// Constituent clips decoded from the compound pool entry (non-empty when isGroup==true
    /// and the compound pool lookup succeeded).  Each element maps to an audio clip pool entry.
    var groupConstituents: [ConstituentClip] = []
    /// clipIdx values for channels 2, 3, … of a multi-mono track (empty for mono).
    /// Each entry is the index into the ClipEntry list for that channel's audio file.
    var companionClipIdxs: [Int] = []
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
    //   Entry classification by typeField + trail[0]:
    //     FOLDER_MARKER:   typeField = 0x00000000, trail[0] = 0x02
    //       → updates the current "subfolder" name (e.g. "Audio Files", "Renamed Audio Files")
    //     AUDIO_FILE:      typeField in { "EVAW","WAVE","AIFF","FFIA","VooM",… }
    //       → audio/video file in the current subfolder (trail varies: 02 xx or 00 ff ff ff ff)
    //     PATH_COMPONENT:  trail[0] = 0x01, trail[1] = depth (1-indexed from volume root)
    //       → directory component; depth 1 = volume name, depth 2+ = subdirectories
    //       → typeField = HFS+ catalog node ID (LE32) of that directory
    //     Other entries:   ignored
    //
    //   Typical ordering within a block:
    //     FOLDER_MARKER, AUDIO_FILE…, PATH_COMPONENT… (path suffix appears after files)

    private static let audioTypeTags: Set<String> = ["WAVE", "AIFF", "EVAW", "FFIA", "VooM"]

    static func extractAudioFiles(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> [AudioFileEntry] {
        var results = [AudioFileEntry]()

        for block in blocks where block.contentType == 0x103a {
            var pos = block.dataOffset + 9   // skip 9-byte block header
            let end = block.dataOffset + block.dataSize
            var currentFolderName = "Audio Files"   // updated when a FOLDER_MARKER is seen

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
                    // Audio file — trail varies but type tag is definitive
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
                    // Folder marker — next batch of files is in this subfolder
                    if !name.isEmpty { currentFolderName = name }
                }
                // trail0 == 0x01 → path component (depth/nodeID), ignored for now

                pos += 4 + Int(nl) + 9   // nameLen(4) + name + typeField(4) + trail(5)
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

        AppLog.shared.log("[PTXBlockDecoder] Video clip pool: \(videoPool.count) entries (first 5: \(videoPool.prefix(5).map(\.name)))")

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
        var colorIndex:   Int     = -1    // PT color index 0–55; -1 = no custom color
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
    //   [6+nameLen+62..63] u16 LE color index (0xffff / 0xfffe = no custom color)

    struct TrackDisplayInfo {
        var hidden:          Set<String>      = []
        var inactive:        Set<String>      = []
        var types:           [String: UInt16] = [:]   // track type code per name
        var orderedNames:    [String]         = []    // all track names in PT mixer order
        var folderMarkers:   Set<String>      = []    // tracks that are folder containers (basic or routing)
        var folderOf:        [String: String] = [:]   // child track → parent folder name
        var colors:          [String: Int]    = [:]   // PT color index per track name
        var channelCounts:   [String: Int]    = [:]   // channel count from 0x251a format byte
        var channelLabels:   [String: String] = [:]   // human-readable label, e.g. "7.1"
    }

    /// Maps the PT channel-format byte (stored at 0x251a[6+nameLen]) to a
    /// channel count and human-readable label string.
    /// Values 0x00–0x10 correspond to PT's internal AudioChannelFormat enum.
    private static func channelInfo(forFormatByte byte: UInt8) -> (count: Int, label: String) {
        switch byte {
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
        default:   return (1,  String(format: "0x%02X", byte))
        }
    }

    static func extractTrackDisplayInfo(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> TrackDisplayInfo {
        guard let b2519 = blocks.first(where: { $0.contentType == 0x2519 }) else { return TrackDisplayInfo() }
        var info = TrackDisplayInfo()
        var seenNames = Set<String>()
        var uidToName = [String: String]()   // 16-char hex UID → track name (for 0x210c parsing)

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
            if seenNames.insert(name).inserted {
                info.orderedNames.append(name)
                // Collect UID for 0x210c folder membership parsing.
                // Layout: [2 typeCode][4 nameLen][name][1 chanFmt][5 zeros][4 0x2a marker][8 UID]
                // → UID starts at nameEndPos + 10
                let uidEnd = nameEndPos + 18
                if uidEnd <= sub.dataOffset + sub.dataSize {
                    let uidHex = (nameEndPos+10..<nameEndPos+18)
                        .map { String(format: "%02x", data[$0]) }.joined()
                    uidToName[uidHex] = name
                }
            }

            // Byte at nameEnd+53 (= p+59+nameLen) is 0x01 for both basic (tc=11) and
            // routing (tc=2) folder tracks, 0x00 for plain Aux/Audio/VCA tracks.
            let folderFlagOffset = nameEndPos + 53
            if folderFlagOffset < sub.dataOffset + sub.dataSize, data[folderFlagOffset] != 0 {
                info.folderMarkers.insert(name)
            }

            // Channel format byte immediately follows the name (0=mono, 1=stereo, etc.)
            if nameEndPos < sub.dataOffset + sub.dataSize {
                let (count, label) = channelInfo(forFormatByte: data[nameEndPos])
                info.channelCounts[name] = count
                info.channelLabels[name] = label
            }

            // Flags and color at fixed offsets from block start (all relative to p)
            let b2Offset    = p + 63 + nameLen   // visible: 0 = hidden
            let b3Offset    = p + 64 + nameLen   // active:  0 = inactive
            let colorOffset = p + 68 + nameLen   // u16 LE color index; ≥0x8000 = no custom color
            guard b3Offset < sub.dataOffset + sub.dataSize else { continue }

            if data[b2Offset] == 0 { info.hidden.insert(name) }
            if data[b3Offset] == 0 { info.inactive.insert(name) }

            if colorOffset + 1 < sub.dataOffset + sub.dataSize {
                let ci = Int(UInt16(data[colorOffset]) | UInt16(data[colorOffset + 1]) << 8)
                if ci < 0x8000 { info.colors[name] = ci }
            }
        }

        // Build folder membership from 0x210c block (definitive parent-child mapping).
        // Falls back to the heuristic stack algorithm if 0x210c is absent.
        let folderOf210c = extractFolderMembership(blocks: blocks, data: data, uidToName: uidToName)
        if !folderOf210c.isEmpty {
            info.folderOf = folderOf210c
        } else {
            // Heuristic fallback: infer folder membership from track ordering.
            //
            // Signals available per 0x251a block:
            //   tc=0x0002 routing folders: post[0]==0x01 → nested (stored as channelCount==2
            //     via channelInfo); post[0]>=0x02 → top-level.
            //   tc=0x000b basic folders: post[0] is always 0x00 regardless of depth.
            //     Heuristic using post[62:64] (color/group index, in info.colors when <0x8000,
            //     defaulting to 0xffff otherwise):
            //       - new folder groupId == stack-top groupId → siblings → pop top.
            //       - last non-folder groupId == stack-top groupId AND folder's color is not
            //         shared with any routing folder → new folder is a child.
            //       - else → not a child here; pop stack top and retry.
            //   tc=0x0002 routing folders cannot parent tc=0x000b basic folders, so when a
            //   tc=0x000b folder appears any routing folders on the stack top are popped first.

            // Pre-pass 1: collect p62 color values of all tc=0x0002 folder tracks.
            var routingFolderColors = Set<Int>()
            for sub in subBlocks {
                let p = sub.dataOffset
                guard p + 6 <= sub.dataOffset + sub.dataSize else { continue }
                let tc2 = UInt16(data[p]) | UInt16(data[p + 1]) << 8
                guard tc2 == 0x0002 else { continue }
                guard let nl2 = safeU32(data, at: p + 2, be: false), nl2 >= 1, nl2 <= 256 else { continue }
                let nameLen2 = Int(nl2)
                let nameEnd2 = p + 6 + nameLen2
                let folderFlagOff2 = nameEnd2 + 53
                guard folderFlagOff2 < sub.dataOffset + sub.dataSize, data[folderFlagOff2] != 0 else { continue }
                let colorOff2 = p + 68 + nameLen2
                if colorOff2 + 1 < sub.dataOffset + sub.dataSize {
                    let ci = Int(UInt16(data[colorOff2]) | UInt16(data[colorOff2 + 1]) << 8)
                    if ci < 0x8000 { routingFolderColors.insert(ci) }
                }
            }

            // Pre-pass 2: find 0x0000 section-boundary blocks within 0x2519.
            let zeroBlocks = blocks.filter {
                $0.contentType == 0x0000 &&
                $0.dataOffset  >= parentStart &&
                $0.dataOffset + $0.dataSize <= parentEnd
            }
            var boundaryOffsets = Set<Int>()
            for zb in zeroBlocks {
                let zbEnd = zb.dataOffset + zb.dataSize
                if let nextSub = subBlocks.first(where: { $0.dataOffset > zb.dataOffset && $0.dataOffset < zbEnd + 500 }) {
                    boundaryOffsets.insert(nextSub.dataOffset)
                }
            }

            // Build a name→dataOffset dictionary (first occurrence only) for boundary lookup.
            var nameToOffset = [String: Int]()
            for sub in subBlocks {
                let p = sub.dataOffset
                guard p + 6 <= sub.dataOffset + sub.dataSize else { continue }
                guard let nl = safeU32(data, at: p + 2, be: false), nl >= 1, nl <= 256 else { continue }
                let nameLen = Int(nl)
                let nameStart = p + 6
                let nameEndPos = nameStart + nameLen
                guard nameEndPos <= sub.dataOffset + sub.dataSize,
                      let name = String(bytes: data[nameStart..<nameEndPos], encoding: .utf8) else { continue }
                if nameToOffset[name] == nil { nameToOffset[name] = p }
            }

            struct StackEntry { var name: String; var tc: UInt16; var groupId: UInt16 }
            var stack: [StackEntry] = []
            var lastNonFolderGroupId: UInt16 = 0xffff

            for name in info.orderedNames {
                let isFolder = info.folderMarkers.contains(name)
                let tc       = info.types[name] ?? 0
                let groupId  = UInt16(info.colors[name] ?? 0xffff)

                if let offset = nameToOffset[name], boundaryOffsets.contains(offset) {
                    while let top = stack.last, top.tc == 0x0002 { stack.removeLast() }
                }

                if isFolder {
                    if tc == 0x0002 {
                        let isNested = (info.channelCounts[name] ?? 0) == 2
                        if !isNested {
                            stack.removeAll()
                        } else {
                            while let top = stack.last, top.tc == 0x0002 { stack.removeLast() }
                        }
                    } else {
                        while let top = stack.last, top.tc == 0x0002 { stack.removeLast() }
                        while let top = stack.last {
                            if top.groupId == groupId {
                                stack.removeLast(); break
                            } else if lastNonFolderGroupId == top.groupId && !routingFolderColors.contains(Int(groupId)) {
                                break
                            } else {
                                stack.removeLast()
                            }
                        }
                    }
                    if let parent = stack.last { info.folderOf[name] = parent.name }
                    stack.append(StackEntry(name: name, tc: tc, groupId: groupId))
                } else {
                    lastNonFolderGroupId = groupId
                    if let parent = stack.last { info.folderOf[name] = parent.name }
                }
            }
        }

        let nonAudioTypes = info.types.filter { $0.value != 0 }.map { "\($0.key)=\($0.value)" }.sorted()
        AppLog.shared.log("[PTXBlockDecoder] Non-audio types: \(nonAudioTypes)")
        AppLog.shared.log("[PTXBlockDecoder] Hidden:   \(info.hidden.sorted())")
        AppLog.shared.log("[PTXBlockDecoder] Inactive: \(info.inactive.sorted())")
        return info
    }

    // MARK: Folder Membership (0x210c)
    //
    // Block 0x210c encodes the explicit parent-child folder hierarchy.
    //
    // Layout:
    //   Header: [u32 folderNodeCount][5 bytes][0x2a 0x00 0x00 0x00]  → first entry at offset+13
    //
    //   Each entry: [8-byte UID][u32 childCount][padding][0x2a 0x00 0x00 0x00 (next entry prefix)]
    //     childCount == 0  → child/leaf record (this track belongs to the current parent)
    //     childCount  > 0  → folder definition (this folder has childCount direct children)
    //     padding = 5 bytes if childCount > 0, 1 byte if childCount == 0
    //
    //   Traversal: depth-first — a folder's N child records immediately follow it,
    //   then any folder children are expanded in order (each appearing twice: once as
    //   a child record with childCount=0, then as a parent record with childCount=M).
    //
    //   Stack algorithm: push folders (childCount>0) onto a stack; for each child record
    //   (childCount=0), assign folderOf[child] = stack.top, decrement top.remaining,
    //   pop when exhausted.

    private static func extractFolderMembership(
        blocks: [PTXBlock], data: Data, uidToName: [String: String]
    ) -> [String: String] {
        guard let b = blocks.first(where: { $0.contentType == 0x210c }),
              b.dataSize >= 13 else { return [:] }

        let blockEnd = b.dataOffset + b.dataSize

        // Parse entries starting at offset+13 (past 4-byte count + 5 padding + 4-byte 0x2a marker).
        // Each entry: UID(8) + childCount(4) + padding(5 if count>0, 1 if count=0).
        // The 4-byte 0x2a marker that precedes the NEXT entry is included in the advance.
        struct Entry { var name: String; var childCount: Int }
        var entries = [Entry]()
        var pos = b.dataOffset + 13

        while pos + 8 <= blockEnd {
            let uidHex = (0..<8).map { String(format: "%02x", data[pos + $0]) }.joined()
            // The last entry in the block may not have a full 4-byte count field (block ends
            // at the UID). Treat those tail bytes as count=0 (always a leaf in practice).
            let count = pos + 12 <= blockEnd ? Int(u32(data, at: pos + 8, be: false)) : 0
            if let name = uidToName[uidHex] {
                entries.append(Entry(name: name, childCount: count))
            }
            // Advance past: UID(8) + childCount(4) + padding(5 or 1) + next 0x2a marker(4)
            let advance = 8 + 4 + (count > 0 ? 5 : 1) + 4
            pos += advance
        }

        guard !entries.isEmpty else { return [:] }

        // Stack-based tree traversal.
        // Folder entries (childCount>0) define direct children; child entries (childCount=0)
        // belong to the current stack-top folder.
        var folderOf = [String: String]()
        var stack = [(name: String, remaining: Int)]()

        for entry in entries {
            if entry.childCount > 0 {
                // Folder node — parent already established when it appeared as a child record
                // (or top-level if first occurrence).
                stack.append((entry.name, entry.childCount))
            } else {
                // Child record
                if let parent = stack.last?.name {
                    folderOf[entry.name] = parent
                }
                if !stack.isEmpty {
                    stack[stack.count - 1].remaining -= 1
                    while !stack.isEmpty && stack.last!.remaining == 0 { stack.removeLast() }
                }
            }
        }

        return folderOf
    }

    /// Builds the compound clip pool from 0x262b parent blocks and their 0x2628 children.
    /// 0x262b blocks are the compound/group clip pool parents (analogous to 0x2629 for audio).
    /// Each 0x2628 child uses the same encoding as audio clip entries.
    /// Returns sparse array indexed by file-order position of the 0x262b parent.
    /// Each entry also includes the constituent clips decoded from the embedded 0x2523 blocks.
    ///
    /// 0x2628 compound entry — extra bytes layout (after the three-point section, before last-2 fileIdx):
    ///   [0..3]   startSample repeated (same value as three-point "start")
    ///   [4..23]  padding / flags
    ///   [24..27] u32 LE constituent count
    ///   [28 + i*97 .. 28 + i*97 + 96]  i-th constituent: 9-byte 0x2523 header + 88-byte content
    ///     Within 0x2523 content (at content offset 0):
    ///       [0..8]   0x2526 block header (9 bytes)
    ///       [9..22]  0x2526 content (14 bytes)
    ///       [23..26] constituent absolute timeline position (u32 LE)
    ///       [39..42] constituent audio clip pool index (u32 LE)
    static func extractCompoundClips(blocks: [PTXBlock], data: Data, bigEndian: Bool)
        -> [(name: String, startSample: Int64, lengthSamples: Int64)?]
    {
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

        var poolByIndex: [Int: (name: String, startSample: Int64, lengthSamples: Int64)] = [:]
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
            vp += nLength
            let startVal = readLE(data, at: vp, count: nStart)  // group's absolute timeline position

            poolByIndex[pIdx] = (name: name, startSample: Int64(bitPattern: startVal),
                                 lengthSamples: Int64(bitPattern: lengthVal))
        }

        return (0..<parentBlocks.count).map { poolByIndex[$0] }
    }

    static func buildTrackPlaylists(blocks: [PTXBlock], data: Data, bigEndian: Bool,
                                    displayInfo: TrackDisplayInfo = TrackDisplayInfo()) -> [TrackPlaylist] {
        // Build compound clip pool: poolIndex → (name, startSample, lengthSamples)
        // Used for group placements; pool is 0x262b→0x2628.
        let compoundPool = extractCompoundClips(blocks: blocks, data: data, bigEndian: bigEndian)

        // ── Sentinel constituent expansion (per-placement) ────────────────────────
        // The second 0x1054 holds one 0x1052 sentinel section per clip group definition.
        // Constituent clipIdx values in sentinel 0x104f blocks address the COMBINED pool
        // (0x2629 audio + 0x262b compound sorted by file offset).
        // For byte18==0x00 track placements, data[33..34] (u16le) is the sentinel ordinal
        // for THAT SPECIFIC PLACEMENT.  The same compound block can appear in different
        // clip groups (each referencing a different sentinel), so we resolve per-placement.
        struct CombinedEntry { let isAudio: Bool; let poolIdx: Int }
        var combinedMap: [Int: CombinedEntry] = [:]
        let audioParents = blocks.filter { $0.contentType == 0x2629 }.sorted { $0.dataOffset < $1.dataOffset }
        let cmpdParents  = blocks.filter { $0.contentType == 0x262b }.sorted { $0.dataOffset < $1.dataOffset }
        do {
            var allEntries: [(off: Int, isAudio: Bool, idx: Int)] = []
            for (i, b) in audioParents.enumerated() { allEntries.append((b.dataOffset, true,  i)) }
            for (i, b) in cmpdParents.enumerated()  { allEntries.append((b.dataOffset, false, i)) }
            allEntries.sort { $0.off < $1.off }
            for (ci, e) in allEntries.enumerated() { combinedMap[ci] = CombinedEntry(isAudio: e.isAudio, poolIdx: e.idx) }
        }

        let all1054sorted = blocks.filter { $0.contentType == 0x1054 }.sorted { $0.dataOffset < $1.dataOffset }
        var sentinelSections: [PTXBlock] = []
        if all1054sorted.count >= 2 {
            let sentContainer = all1054sorted[1]
            let sStart = sentContainer.dataOffset, sEnd = sStart + sentContainer.dataSize
            let innerRanges = blocks.filter {
                $0.contentType == 0x1054 && $0.dataOffset > sStart && $0.dataOffset + $0.dataSize <= sEnd
            }.map { ($0.dataOffset, $0.dataOffset + $0.dataSize) }
            sentinelSections = blocks.filter { blk in
                blk.contentType == 0x1052 &&
                blk.dataOffset >= sStart && blk.dataOffset + blk.dataSize <= sEnd &&
                !innerRanges.contains { r in r.0 <= blk.dataOffset && blk.dataOffset + blk.dataSize <= r.1 }
            }.sorted { $0.dataOffset < $1.dataOffset }
        }
        let SENT_ORIGIN: UInt64 = 1_000_000_000_000

        // Expand a sentinel ordinal into constituent clips.  Called per-placement so each
        // instance of a compound gets the correct sentinel for that specific clip group.
        func expandSentinel(_ ordinal: Int, baseOffset: Int64, depth: Int) -> [ConstituentClip] {
            guard depth < 8, ordinal < sentinelSections.count else { return [] }
            let section = sentinelSections[ordinal]
            let secEnd = section.dataOffset + section.dataSize
            let pls = blocks.filter {
                $0.contentType == 0x104f &&
                $0.dataOffset >= section.dataOffset && $0.dataOffset + $0.dataSize <= secEnd
            }.sorted { $0.dataOffset < $1.dataOffset }
            var result: [ConstituentClip] = []
            for pl in pls {
                guard pl.dataSize >= 19 else { continue }
                let ci   = Int(readLE(data, at: pl.dataOffset + 2, count: 2))
                let tl   = readLE(data, at: pl.dataOffset + 7, count: 8)
                guard tl >= SENT_ORIGIN else { continue }
                let relOff = baseOffset + Int64(bitPattern: tl - SENT_ORIGIN)
                if data[pl.dataOffset + 18] == 0x00 {
                    if let ce = combinedMap[ci] {
                        if ce.isAudio {
                            result.append(ConstituentClip(audioClipIdx: ce.poolIdx, relativeOffset: relOff))
                        } else if let comp = compoundPool[ce.poolIdx] {
                            result.append(ConstituentClip(audioClipIdx: ce.poolIdx, relativeOffset: relOff,
                                                          isSubGroup: true, subGroupName: comp.name,
                                                          subGroupLength: comp.lengthSamples))
                        }
                    }
                } else {
                    // Nested sub-group: translate combined index → compound pool index, then recurse
                    let compOrdinal = combinedMap[ci].map { $0.isAudio ? ci : $0.poolIdx } ?? ci
                    result += expandSentinel(compOrdinal, baseOffset: relOff, depth: depth + 1)
                }
            }
            return result
        }

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

        // Nameless sections (nl=0): collect separately for a second pass.
        // These occur in some sessions (e.g. inactive tracks imported from AAF) where PT writes
        // the 0x1052 block without an inline name.  We match them to audio tracks in orderedNames
        // that were not claimed by any named section, preserving mixer order.
        var namelessSections: [PTXBlock] = []

        for (_, section) in trackSections.enumerated() {
            // Read track name: [u32 nameLen][nameBytes].
            let name: String
            if let nameLen = safeU32(data, at: section.dataOffset, be: false),
               nameLen >= 1, nameLen <= 256,
               section.dataOffset + 4 + Int(nameLen) <= data.count,
               let n = String(bytes: data[section.dataOffset + 4 ..< section.dataOffset + 4 + Int(nameLen)],
                              encoding: .utf8) {
                name = n
            } else {
                // displayInfo available but section has no inline name — defer to second pass.
                namelessSections.append(section)
                continue
            }

            // If we have a display list, skip any 0x1052 section whose name is not in it.
            // Those sections are alternate playlists (different clip sets on the same track),
            // not separate tracks — they share the primary track's channel strip and plugins.
            if !displayInfo.types.isEmpty, displayInfo.types[name] == nil { continue }

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
            // Per-section pass: collect compound clipIdx values from byte18=0x01 placements
            // on THIS track only.  Used to detect copy placements (byte18=0x00, same clipIdx).
            // Must be per-section to avoid cross-track contamination — compound pool and audio
            // pool both start at 0, so a compound index on track A could match an audio index
            // on track B if we built the set globally.
            let sectionGroupIdxSet: Set<Int> = {
                var s = Set<Int>()
                for ref in refs {
                    guard ref.dataSize >= 19, parent1050(of: ref) != nil else { continue }
                    var rawTL: UInt64 = 0
                    for k in 0..<min(8, ref.dataSize - 7) { rawTL |= UInt64(data[ref.dataOffset + 7 + k]) << (k * 8) }
                    guard rawTL < 1_000_000_000_000, rawTL > 0 else { continue }
                    if data[ref.dataOffset + 18] == 0x01 { s.insert(Int(u16(data, at: ref.dataOffset + 2, be: bigEndian))) }
                }
                return s
            }()

            let placements: [ClipPlacement] = refs.compactMap { ref in
                guard parent1050(of: ref) != nil else { return nil }  // reject false positives
                // 0x104f byte[0]: 0x01 = muted
                // 0x104f byte[18]: 0x01 = compound group original-def placement
                //                  0x00 = audio clip OR compound copy placement
                //         Detect copy placements by matching clipIdx against this track's group set.
                // 0x104f byte[35]: 0x00 = visible on timeline, 0x01 = hidden dialog/sync ref
                let byte0    = ref.dataSize >= 1  ? data[ref.dataOffset]      : 0x00
                let byte18   = ref.dataSize >= 19 ? data[ref.dataOffset + 18] : 0x01
                let isMuted  = byte0 == 0x01
                let isHidden = ref.dataSize >= 36 && data[ref.dataOffset + 35] == 0x01
                let clipIdx  = Int(u16(data, at: ref.dataOffset + 2, be: bigEndian))
                let isGroup  = byte18 == 0x01 || (byte18 == 0x00 && sectionGroupIdxSet.contains(clipIdx))
                // Timeline: 5-byte sample position stored as u64 LE; sentinel value
                // (1_000_000_000_000 = 0xE8D4A51000) marks constituent refs, not real placements.
                let rawTL = readLE(data, at: ref.dataOffset + 7, count: 8)
                guard rawTL < 1_000_000_000_000 else { return nil }
                let timeline = Int64(bitPattern: rawTL)
                guard timeline >= 0 else { return nil }
                let compoundEntry = isGroup ? compoundPool[clipIdx] : nil
                let groupName   = compoundEntry?.name
                let groupLength = compoundEntry?.lengthSamples
                // Resolve constituents per-placement.
                // byte18==0x01 original-def: sentinel ordinal == clipIdx (compound pool index).
                // byte18==0x00 copy placement: sentinel ordinal in data[33..34].
                let groupConstituents: [ConstituentClip]
                if isGroup {
                    let sentOrd: Int
                    if byte18 == 0x01 {
                        sentOrd = clipIdx
                    } else if ref.dataSize >= 35 {
                        sentOrd = Int(readLE(data, at: ref.dataOffset + 33, count: 2))
                    } else {
                        sentOrd = clipIdx
                    }
                    groupConstituents = expandSentinel(sentOrd, baseOffset: 0, depth: 0)
                } else {
                    groupConstituents = []
                }
                return ClipPlacement(clipIdx: clipIdx, timelineSample: timeline, trackHint: 0,
                                     isHidden: isHidden, isMuted: isMuted, isGroup: isGroup,
                                     groupName: groupName, groupLength: groupLength,
                                     groupConstituents: groupConstituents)
            }

            // Only the FIRST 0x1052 section for each track name drives timeline positions.
            // For stereo/surround tracks the additional channel sections share the same
            // timeline positions as the first but reference different audio files.
            // Capture their clipIdx values keyed by timeline position so PTXParser can
            // resolve each channel's audio file name from the clip pool.
            if channelCounts[name] == nil {
                nameOrder.append(name)
                placementsByName[name] = placements
                channelCounts[name] = 1
            } else {
                let prevCount = channelCounts[name]!
                channelCounts[name]! += 1
                // Only capture companions for genuine additional audio channels.
                // A track with N audio channels has N consecutive 0x1052 blocks;
                // any further blocks with the same name are alternate playlists and must be skipped.
                // Use the authoritative channel count from the 0x251a format byte when available.
                let audioChannels = displayInfo.channelCounts[name] ?? (prevCount + 1)
                guard prevCount < audioChannels else { continue }
                // Build timeline→clipIdx map for this additional channel.
                var companionByTimeline: [Int64: Int] = [:]
                for p in placements where !p.isHidden {
                    companionByTimeline[p.timelineSample] = p.clipIdx
                }
                // Attach companion clipIdx to each first-channel placement at the same position.
                if var arr = placementsByName[name] {
                    for i in arr.indices {
                        if let idx = companionByTimeline[arr[i].timelineSample] {
                            arr[i].companionClipIdxs.append(idx)
                        }
                    }
                    placementsByName[name] = arr
                }
            }
        }

        // Second pass: assign nameless sections to audio tracks in orderedNames that were not
        // claimed by any named section above.  This handles inactive/AAF-imported tracks whose
        // 0x1052 blocks have nl=0.  We preserve the mixer order from orderedNames.
        if !namelessSections.isEmpty && !displayInfo.orderedNames.isEmpty {
            let unmatched = displayInfo.orderedNames.filter {
                displayInfo.types[$0] == 0x00 && channelCounts[$0] == nil
            }
            for (i, section) in namelessSections.enumerated() {
                guard i < unmatched.count else { break }
                let name = unmatched[i]
                // Extract placements using the same logic as the main loop.
                let sStart = section.dataOffset, sEnd = section.dataOffset + section.dataSize
                var lo2 = 0, hi2 = sortedRefs.count
                while lo2 < hi2 { let m = (lo2+hi2)/2; if sortedRefs[m].dataOffset < sStart { lo2 = m+1 } else { hi2 = m } }
                var refs2: [PTXBlock] = []
                var j2 = lo2
                while j2 < sortedRefs.count && sortedRefs[j2].dataOffset >= sStart {
                    let r = sortedRefs[j2]
                    if r.dataOffset + r.dataSize <= sEnd { refs2.append(r) } else { break }
                    j2 += 1
                }
                // Per-section group set for nameless section (same per-track logic as main loop).
                let namelessGroupIdxSet: Set<Int> = {
                    var s = Set<Int>()
                    for ref in refs2 {
                        guard ref.dataSize >= 19, parent1050(of: ref) != nil else { continue }
                        let tl = Int64(u32(data, at: ref.dataOffset + 7, be: bigEndian))
                        guard tl > 0 else { continue }
                        if data[ref.dataOffset + 18] == 0x01 { s.insert(Int(u16(data, at: ref.dataOffset + 2, be: bigEndian))) }
                    }
                    return s
                }()
                let placements: [ClipPlacement] = refs2.compactMap { ref in
                    guard parent1050(of: ref) != nil else { return nil }
                    let byte0  = ref.dataSize >= 1  ? data[ref.dataOffset]      : 0x00
                    let byte18 = ref.dataSize >= 19 ? data[ref.dataOffset + 18] : 0x01
                    let isHidden = ref.dataSize >= 36 && data[ref.dataOffset + 35] == 0x01
                    let clipIdx  = Int(u16(data, at: ref.dataOffset + 2, be: bigEndian))
                    let timeline = Int64(u32(data, at: ref.dataOffset + 7, be: bigEndian))
                    guard timeline >= 0 else { return nil }
                    let isMuted = byte0 == 0x01
                    let isGroup = byte18 == 0x01 || (byte18 == 0x00 && namelessGroupIdxSet.contains(clipIdx))
                    let compoundEntry = isGroup ? compoundPool[clipIdx] : nil
                    let groupConstituents: [ConstituentClip]
                    if isGroup {
                        let sentOrd: Int
                        if byte18 == 0x01 {
                            sentOrd = clipIdx
                        } else if ref.dataSize >= 35 {
                            sentOrd = Int(readLE(data, at: ref.dataOffset + 33, count: 2))
                        } else {
                            sentOrd = clipIdx
                        }
                        groupConstituents = expandSentinel(sentOrd, baseOffset: 0, depth: 0)
                    } else {
                        groupConstituents = []
                    }
                    return ClipPlacement(clipIdx: clipIdx, timelineSample: timeline, trackHint: 0,
                                         isHidden: isHidden, isMuted: isMuted, isGroup: isGroup,
                                         groupName: compoundEntry?.name, groupLength: compoundEntry?.lengthSamples,
                                         groupConstituents: groupConstituents)
                }
                if channelCounts[name] == nil {
                    nameOrder.append(name)
                    placementsByName[name] = placements
                    channelCounts[name] = 1
                } else {
                    channelCounts[name]! += 1
                }
            }
        }

        return nameOrder.map { name in
            // Prefer the explicit format byte from 0x251a — it is authoritative for all
            // track types including Aux and Master.  Fall back to 0x1052 section counting
            // (which works for audio playlist tracks but gives 1 for non-playlist tracks).
            let count = displayInfo.channelCounts[name] ?? channelCounts[name] ?? 1
            return TrackPlaylist(
                name: name,
                channelCount: count,
                placements: placementsByName[name] ?? [],
                isHidden: displayInfo.hidden.contains(name),
                isInactive: displayInfo.inactive.contains(name),
                trackTypeCode: displayInfo.types[name] ?? 0,
                folderName: displayInfo.folderOf[name],
                colorIndex: displayInfo.colors[name] ?? -1
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
            if tcEnum < tcFormats.count {
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

    /// Returns (orderedNames, secondStrings) where secondStrings maps display name →
    /// the PTX "second string" field (reverse-DNS bundle ID for most plugins,
    /// or a variant/format name like "RX 9 Monitor Mono" for iZotope plugins).
    static func extractPlugins(blocks: [PTXBlock], data: Data) -> (names: [String], secondStrings: [String: String]) {
        var seen = Set<String>()
        var result = [String]()
        var seconds = [String: String]()
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
            // Second string: display_name + 12 OSType bytes + 4 flags + 3 bytes = +19
            let secondOff = p + 5 + Int(nl) + 19
            if seconds[name] == nil,
               secondOff + 4 <= block.dataOffset + block.dataSize,
               let sl = safeU32(data, at: secondOff, be: false), sl > 0, sl <= 512,
               secondOff + 4 + Int(sl) <= block.dataOffset + block.dataSize {
                let slice = data[(secondOff + 4) ..< (secondOff + 4 + Int(sl))]
                if let s = String(bytes: slice, encoding: .utf8), !s.isEmpty {
                    seconds[name] = s
                }
            }
            if seen.insert(name).inserted {
                result.append(name)
            }
        }
        return (result, seconds)
    }

    // MARK: Per-track Plugin Extraction
    //
    // Each track has a 0x102d "mixer strip" block followed by a 0x2627 block holding all
    // insert-slot state. The 0x2627 content starts with a 2-byte prefix then a sequence of
    // per-slot records (up to 10, A–J):
    //
    //   Empty slot  → 0x2625 block, size=11
    //   Occupied slot → 0x2616 block, size=varies
    //
    // Consecutive slot records OVERLAP by 2 bytes: the last 2 bytes of each record's content
    // are the first 2 bytes of the next record's block header. Advance = 9 + size - 2.
    //
    // The AAX OSType key (8 bytes, maps to plugin display name) sits at content+56 within
    // every occupied (0x2616) slot.
    //
    // Returns: trackName → ordered list of plugin display names (slot order, skipping empties)

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
            let base = p + 5 + Int(nl)
            let ot0 = String(bytes: data[base..<base+4].reversed(), encoding: .utf8) ?? ""
            let ot1 = String(bytes: data[base+4..<base+8].reversed(), encoding: .utf8) ?? ""
            let key = ot0 + ot1
            if key.count == 8 { keyToPlugin[key] = name }
        }
        guard !keyToPlugin.isEmpty else { return [:] }

        // Collect 0x102d mixer-strip blocks in file order.
        // Each 0x102d wraps a 0x2619 sub-block whose layout (relative to dataOffset+9) is:
        //   [0-3]  u32 LE nameLen
        //   [4..4+nameLen-1]  strip display name (may be old/renamed, e.g. "Audio 1")
        //   [4+nameLen .. 4+nameLen+10]  11-byte suffix: 01 00 | 01 00 00 00 | 00 | 2a 00 00 00
        //   [4+nameLen+11 .. 4+nameLen+18]  8-byte strip UID
        struct StripInfo { var name: String; var uid: String; var end: Int }
        var strips: [StripInfo] = []
        for b in sorted where b.contentType == 0x102d {
            let p = b.dataOffset + 9   // past 0x2619 block header
            guard let nl = safeU32(data, at: p, be: false),
                  nl >= 1, nl <= 64,
                  p + 4 + Int(nl) <= data.count,
                  let name = String(bytes: data[(p+4)..<(p+4+Int(nl))], encoding: .utf8),
                  !name.isEmpty else { continue }
            let uidStart = p + 4 + Int(nl) + 11
            let uid: String
            if uidStart + 8 <= data.count {
                uid = data[uidStart..<(uidStart+8)].map { String(format: "%02x", $0) }.joined()
            } else {
                uid = ""
            }
            strips.append(StripInfo(name: name, uid: uid, end: b.dataOffset + b.dataSize))
        }

        // For each strip, find its following 0x2627 plugin-state block and parse occupied slots.
        var uidToPlugins:  [String: [String]] = [:]   // strip UID  → plugins
        var nameToPlugins: [String: [String]] = [:]   // strip name → plugins (fallback)
        for (i, tb) in strips.enumerated() {
            let ceiling = i + 1 < strips.count ? strips[i + 1].end - 300 : Int.max
            let stateBlocks = sorted.filter {
                $0.contentType == 0x2627 &&
                $0.dataOffset >= tb.end &&
                $0.dataOffset < ceiling
            }
            guard let pb = stateBlocks.first else { continue }

            // Sequential slot parse: 2-byte prefix, then up to 10 slot records.
            // Advance = 9 + size - 2 (consecutive records overlap by 2 bytes).
            let blockBase = pb.dataOffset
            var pos = 2   // skip 2-byte prefix
            var plugins: [String] = []

            for _ in 0 ..< 10 {
                guard pos + 9 < pb.dataSize,
                      data[blockBase + pos] == 0x5a,
                      let sz = safeU32(data, at: blockBase + pos + 3, be: false),
                      sz > 0, sz < 50_000_000,
                      blockBase + pos + 9 + Int(sz) <= blockBase + pb.dataSize
                else { break }

                let ct = UInt16(data[blockBase + pos + 7]) | UInt16(data[blockBase + pos + 8]) << 8

                if ct == 0x2616 {
                    // Occupied slot: OSType key at content + 56
                    let keyBase = blockBase + pos + 9 + 56
                    if keyBase + 8 <= blockBase + pb.dataSize {
                        let w = data[keyBase ..< keyBase + 8]
                        if w.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
                           let key = String(bytes: w, encoding: .utf8),
                           let pluginName = keyToPlugin[key] {
                            plugins.append(pluginName)
                        }
                    }
                }
                // 0x2625 = empty slot, skip silently.

                pos += 9 + Int(sz) - 2
            }

            if !plugins.isEmpty {
                if !tb.uid.isEmpty { uidToPlugins[tb.uid] = plugins }
                nameToPlugins[tb.name] = plugins
            }
        }

        // Parse 0x210b blocks: track display name → 8-byte UID.
        // These blocks are emitted as top-level entries in the decoded block list (130 in a
        // typical session). Data layout at b.dataOffset:
        //   [0-3]  00 00 00 00
        //   [4-7]  u32 LE nameLen
        //   [8..8+nameLen-1]  track display name
        //   [8+nameLen..8+nameLen+7]  00 00 00 00 | 2a 00 00 00
        //   [8+nameLen+8..8+nameLen+15]  8-byte track UID
        var trackToUID: [(trackName: String, uid: String)] = []
        for b in sorted where b.contentType == 0x210b {
            let doff = b.dataOffset
            guard b.dataSize >= 24,
                  let nl = safeU32(data, at: doff + 4, be: false),
                  nl >= 1, nl <= 256,
                  doff + 8 + Int(nl) + 8 + 8 <= data.count,
                  let tname = String(bytes: data[(doff+8)..<(doff+8+Int(nl))], encoding: .utf8),
                  !tname.isEmpty else { continue }
            let uidStart = doff + 8 + Int(nl) + 8
            let uid = data[uidStart..<(uidStart+8)].map { String(format: "%02x", $0) }.joined()
            trackToUID.append((trackName: tname, uid: uid))
        }

        var result: [String: [String]] = [:]

        // Pass 1: UID-based match (handles renamed tracks — "1 dx" finds "Audio 1" strip via UID)
        var resolvedUIDs = Set<String>()
        for (trackName, uid) in trackToUID {
            if let plugins = uidToPlugins[uid] {
                result[trackName] = plugins
                resolvedUIDs.insert(uid)
            }
        }

        // Pass 2: strip-name fallback for any strip not already resolved via UID
        // (covers sessions without 0x2107, or extra strips absent from the map)
        for tb in strips {
            guard !tb.uid.isEmpty ? !resolvedUIDs.contains(tb.uid) : result[tb.name] == nil else { continue }
            if let plugins = nameToPlugins[tb.name] {
                result[tb.name] = plugins
            }
        }

        return result
    }

    // MARK: Track Routing (I/O paths)
    //
    // Each 0x261b block is a per-track container holding the mixer strip (0x102d) and routing data.
    //
    // Output path: LP string at offset +36 within the first 0x260e block that is inside a 0x260d
    //   block inside this 0x261b container. Bytes 0–1 of 0x260e = 0xff 0xff → no path assigned.
    //
    // Input path: stored as raw bytes in the container's tail (after all child blocks).
    //   Pattern: {00 00 00 00} sentinel {4 bytes} separator {00} {u32le len} {UTF-8 string}
    //   If no valid LP string follows the sentinel, the track has no input path.

    struct RoutingEntry {
        var inputPath:    String?
        var outputPath:   String?
        var isAtmosObject: Bool = false  // true = Atmos Object send (b2 != 0xff && b2 != 0x00)
        var isAtmosBed:    Bool = false  // true = Atmos Bed send (flagOff+11 != 0xff = Atmos group id)
        var atmosRendererInput: Int = 0  // 1-indexed renderer input channel (b11+1); 0 = unknown
        var bedChannelCount: Int = 0     // BED assignment width in channels (decoded from b1); 0 = unknown
        var sendPaths:    [String] = []  // aux send bus names
    }

    /// Decode routing-block BED format byte → channel count.
    /// This table differs from 0x251a: values above 5.1 are encoded differently.
    private static func bedChannelCount(routingFormatByte b: UInt8) -> Int {
        switch b {
        case 0x00: return 1
        case 0x01: return 2
        case 0x02: return 3
        case 0x03, 0x04: return 4
        case 0x05: return 5
        case 0x06: return 6
        case 0x0e: return 8   // 7.1
        case 0x11: return 10  // 7.1.2
        default:   return 0   // unknown → show "BED N" without range
        }
    }

    /// Returns a dictionary mapping track display names → routing entry (inputPath, outputPath).
    /// Uses UID-based matching (via 0x210b blocks) to handle renamed tracks, with a strip-name
    /// fallback — mirroring the same two-pass strategy as extractTrackPlugins.
    static func extractRouting(blocks: [PTXBlock], data: Data, bigEndian: Bool) -> [String: RoutingEntry] {
        let sorted = blocks.sorted { $0.dataOffset < $1.dataOffset }

        let all261b = sorted.filter { $0.contentType == 0x261b }
        let all260d  = sorted.filter { $0.contentType == 0x260d }
        let all260e  = sorted.filter { $0.contentType == 0x260e }

        // Per-strip routing data collected from 0x261b containers
        struct StripRouting { var name: String; var uid: String; var entry: RoutingEntry }
        var strips: [StripRouting] = []

        for container in all261b {
            let cStart = container.dataOffset
            let cEnd   = container.dataOffset + container.dataSize

            // Track name + UID from 0x102d strip.
            // Layout at strip.dataOffset + 9 (past 0x2619 sub-block header):
            //   [0-3]  u32 LE nameLen
            //   [4..4+nl-1]  strip name
            //   [4+nl .. 4+nl+10]  11-byte suffix
            //   [4+nl+11 .. 4+nl+18]  8-byte strip UID
            guard let strip = sorted.first(where: {
                $0.contentType == 0x102d &&
                $0.dataOffset >= cStart && $0.dataOffset + $0.dataSize <= cEnd
            }) else { continue }

            let nameOff = strip.dataOffset + 9
            guard let nl = safeU32(data, at: nameOff, be: false),
                  nl >= 1, nl <= 64,
                  nameOff + 4 + Int(nl) <= data.count,
                  let name = String(bytes: data[(nameOff+4)..<(nameOff+4+Int(nl))], encoding: .utf8),
                  !name.isEmpty else { continue }

            let uidStart = nameOff + 4 + Int(nl) + 11
            let uid: String
            if uidStart + 8 <= data.count {
                uid = data[uidStart..<(uidStart+8)].map { String(format: "%02x", $0) }.joined()
            } else {
                uid = ""
            }

            // ── Output path + sends ──────────────────────────────────────────
            // All 0x260e blocks nested inside a 0x260d in this container encode routing.
            // Discriminant: byte[0] of the 0x260e data:
            //   0x13 → aux send (all tracks sending to the same bus share a common bus UID)
            //   other → main output
            // LP string is at offset +36 in all cases.
            // Atmos flags (Object/Bed) apply only to the main output block.
            var outputPath: String? = nil
            var sendPaths: [String] = []
            var isAtmosObject = false
            var isAtmosBed    = false
            var isAtmosRendererInput = 0
            var atmosBedChannelCount = 0

            let routingBlocks = all260e.filter { e in
                guard e.dataOffset >= cStart, e.dataOffset + e.dataSize <= cEnd else { return false }
                return all260d.contains(where: { d in
                    d.dataOffset >= cStart && d.dataOffset + d.dataSize <= cEnd &&
                    e.dataOffset >= d.dataOffset && e.dataOffset + e.dataSize <= d.dataOffset + d.dataSize
                })
            }

            for pathBlock in routingBlocks {
                guard pathBlock.dataSize >= 2,
                      !(data[pathBlock.dataOffset] == 0xff && data[pathBlock.dataOffset + 1] == 0xff)
                else { continue }

                let isSend = outputPath != nil  // first valid block = main output; rest = sends
                let lpOff  = pathBlock.dataOffset + 36
                guard lpOff + 4 <= pathBlock.dataOffset + pathBlock.dataSize,
                      let sl = safeU32(data, at: lpOff, be: false),
                      sl > 0, sl <= 256,
                      lpOff + 4 + Int(sl) <= pathBlock.dataOffset + pathBlock.dataSize,
                      let s = String(bytes: data[(lpOff+4)..<(lpOff+4+Int(sl))], encoding: .utf8),
                      !s.isEmpty else { continue }

                if isSend {
                    if !sendPaths.contains(s) { sendPaths.append(s) }
                } else if outputPath == nil {
                    outputPath = s
                    // Read Atmos routing bytes immediately after the output path string.
                    // Layout: [b0: chanFmt][b1: chanFmt][b2..b9: 0xff = plain bus, else Object slot]
                    //         [b10: 0x00][b11: Atmos group id, 0xff = not a Bed]
                    //   Object: b2 != 0xff && b2 != 0x00 && b0==0x00 && b1==0x00 (b2=object slot)
                    //   Bed:    b11 != 0xff (Atmos group: 0x00=Dialog, 0x0a=Music, etc.)
                    let flagOff = lpOff + 4 + Int(sl)
                    if flagOff + 12 <= pathBlock.dataOffset + pathBlock.dataSize {
                        let b1  = data[flagOff + 1], b2 = data[flagOff + 2]
                        let b11 = data[flagOff + 11]
                        isAtmosObject = b2 != 0xff && b2 != 0x00
                        isAtmosBed    = !isAtmosObject && b11 != 0xff
                        // b11 is 0-indexed renderer input; +1 gives the 1-indexed channel shown in PT
                        if isAtmosObject || isAtmosBed { isAtmosRendererInput = Int(b11) + 1 }
                        if isAtmosBed { atmosBedChannelCount = PTXBlockDecoder.bedChannelCount(routingFormatByte: b1) }
                    } else if flagOff + 3 <= pathBlock.dataOffset + pathBlock.dataSize {
                        let b2 = data[flagOff + 2]
                        isAtmosObject = b2 != 0xff && b2 != 0x00
                    }
                }
            }

            // ── Input path ────────────────────────────────────────────────────
            // Scan from end of last child block forward, looking for the pattern:
            //   {00 00 00 00} {4 bytes} {00} {u32le LP length} {string}
            var inputPath: String? = nil
            let lastChildEnd = blocks
                .filter {
                    $0.dataOffset >= cStart &&
                    $0.dataOffset + $0.dataSize <= cEnd &&
                    !($0.dataOffset == cStart && $0.dataSize == container.dataSize) // exclude container itself
                }
                .map { $0.dataOffset + $0.dataSize }
                .max() ?? cStart

            var pos = lastChildEnd
            while pos + 9 < cEnd, inputPath == nil {
                if data[pos] == 0 && data[pos+1] == 0 && data[pos+2] == 0 && data[pos+3] == 0 {
                    let lpOff = pos + 9   // skip sentinel(4) + format(4) + separator(1)
                    if lpOff + 4 <= cEnd,
                       let sl = safeU32(data, at: lpOff, be: false),
                       sl > 0, sl <= 128, lpOff + 4 + Int(sl) <= cEnd {
                        let bytes = data[(lpOff+4)..<(lpOff+4+Int(sl))]
                        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                           let s = String(bytes: bytes, encoding: .utf8), !s.isEmpty {
                            inputPath = s
                        }
                    }
                }
                pos += 1
            }

            guard outputPath != nil || inputPath != nil else { continue }
            strips.append(StripRouting(name: name, uid: uid,
                                       entry: RoutingEntry(inputPath: inputPath, outputPath: outputPath,
                                                           isAtmosObject: isAtmosObject,
                                                           isAtmosBed: isAtmosBed,
                                                           atmosRendererInput: isAtmosRendererInput,
                                                           bedChannelCount: atmosBedChannelCount,
                                                           sendPaths: sendPaths)))
        }

        // Build UID → routing lookup
        var uidToRouting: [String: RoutingEntry] = [:]
        for s in strips where !s.uid.isEmpty { uidToRouting[s.uid] = s.entry }

        // Parse 0x210b blocks: display name → 8-byte UID (same layout as in extractTrackPlugins)
        var trackToUID: [(trackName: String, uid: String)] = []
        for b in sorted where b.contentType == 0x210b {
            let doff = b.dataOffset
            guard b.dataSize >= 24,
                  let nl = safeU32(data, at: doff + 4, be: false),
                  nl >= 1, nl <= 256,
                  doff + 8 + Int(nl) + 8 + 8 <= data.count,
                  let tname = String(bytes: data[(doff+8)..<(doff+8+Int(nl))], encoding: .utf8),
                  !tname.isEmpty else { continue }
            let uidStart = doff + 8 + Int(nl) + 8
            let uid = data[uidStart..<(uidStart+8)].map { String(format: "%02x", $0) }.joined()
            trackToUID.append((trackName: tname, uid: uid))
        }

        var result: [String: RoutingEntry] = [:]

        // Pass 1: UID-based match (handles renamed tracks)
        var resolvedUIDs = Set<String>()
        for (trackName, uid) in trackToUID {
            if let entry = uidToRouting[uid] {
                result[trackName] = entry
                resolvedUIDs.insert(uid)
            }
        }

        // Pass 2: strip-name fallback for any strip not already resolved via UID
        for s in strips {
            guard !s.uid.isEmpty ? !resolvedUIDs.contains(s.uid) : result[s.name] == nil else { continue }
            result[s.name] = s.entry
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
