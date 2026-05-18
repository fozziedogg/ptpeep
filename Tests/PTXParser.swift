import Foundation

// MARK: - PTX Binary Parser
//
// Parses Avid Pro Tools .ptx session files (PT 10+).
//
// The early section of .ptx is plaintext with 4-byte LE length-prefixed strings.
// Layout (offsets are approximate and version-dependent):
//   0x00-0x11  Header / version bytes
//   0x12       Format type byte (0x05 = PT 10+)
//   0x13       XOR key byte (used in encrypted sections, not the early plaintext area)
//   0x14-0x37  Binary header fields (session metadata encoded as enums - not yet decoded)
//   0x3a-0x3d  Unrelated preset block (not memory locations)
//   0x8d-???   Session path (4-byte LE component count, then components as len+string)
//   0x130+     Track names (4-byte LE length-prefixed, repeated 3-4x)

final class PTXParser {

    // MARK: - Public API

    static func parse(url: URL) throws -> PTXSession {
        let data = try Data(contentsOf: url)
        var session = PTXSession()
        session.sessionPath = url.path
        session.sessionName = url.deletingPathExtension().lastPathComponent

        let scanner = BinaryScanner(data: data)

        parseSessionPath(scanner: scanner, session: &session)
        parseStrings(data: data, session: &session)
        parseBlockContent(data: data, session: &session)

        return session
    }

    // MARK: - Session path
    // Immediately follows the memory location block (after padding).

    private static func parseSessionPath(scanner: BinaryScanner, session: inout PTXSession) {
        // Find "Macintosh HD" or a Users component near the beginning to locate path block.
        guard let pos = scanner.findString("Macintosh HD", searchLimit: 512) else { return }
        // Walk back to the 4-byte LE length prefix
        let nameStart = pos - 4
        guard nameStart >= 0 else { return }
        // Walk back further to find the component count
        // The component count is 4 bytes before the first component's length prefix
        let countPos = nameStart - 4
        guard let componentCount = scanner.readUInt32LE(at: countPos),
              componentCount > 0, componentCount < 20 else { return }

        var p = nameStart
        var components: [String] = []
        // Read componentCount path segments (directory parts only, not the .ptx filename)
        for _ in 0..<Int(componentCount) {
            guard let s = scanner.readLEString(at: p) else { break }
            components.append(s)
            p += 4 + s.utf8.count
        }
        // The .ptx filename typically follows the directory components
        if let filename = scanner.readLEString(at: p), filename.hasSuffix(".ptx") {
            let dir = "/" + components.dropFirst().joined(separator: "/")  // drop "Macintosh HD"
            session.sessionPath = dir + "/" + filename
            session.sessionName = String(filename.dropLast(4))
        }
    }

    // MARK: - Track names
    // Scan the binary from 0x100 onward for 4-byte LE length-prefixed printable ASCII strings.
    // Strings repeat 3-4x in the file; the first occurrence (before ~0x500) is the track name.
    // We cannot reliably distinguish track names from audio file base names by content alone —
    // tracks are often named identically to their audio files — so everything in the early
    // section is treated as a track name. Audio file names come from the folder scan instead.

    private static func parseStrings(data: Data, session: inout PTXSession) {
        var seen = Set<String>()
        var i = 0x100   // skip header / memory-locations / path block
        let scanLimit = min(data.count, 0x2000)  // track names live in first few KB; block decoder overrides anyway
        while i + 4 < scanLimit {
            let slen = Int(data.loadLE(UInt32.self, at: i))
            guard slen >= 2, slen <= 200, i + 4 + slen <= data.count else {
                i += 1
                continue
            }
            let slice = data[i+4 ..< i+4+slen]
            guard slice.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                  let s = String(bytes: slice, encoding: .utf8) else {
                i += 1
                continue
            }

            // Valid string found — always advance past it
            let advance = 4 + slen
            if !seen.contains(s) {
                seen.insert(s)
                if i < 0x500,
                   !s.hasSuffix(".ptx"),
                   s != session.sessionName,
                   !s.hasPrefix("Info #") {
                    session.tracks.append(PTXTrack(index: session.tracks.count, name: s, type: .audio))
                }
            }
            i += advance
        }
    }

    // MARK: - Block content (XOR-decoded clip + track data)

    private static func parseBlockContent(data: Data, session: inout PTXSession) {
        guard let decoded = PTXBlockDecoder.xorDecode(data) else {
            print("[PTXParser] XOR decode failed — unrecognised format byte 0x\(String(data[0x12], radix: 16))")
            return
        }
        let bigEndian = PTXBlockDecoder.isBigEndian(decoded)
        let blocks    = PTXBlockDecoder.scanBlocks(data: decoded, bigEndian: bigEndian)

        // Log block type summary
        let typeCounts = Dictionary(grouping: blocks, by: \.contentType)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
        print("[PTXParser] XOR decoded \(decoded.count) bytes, bigEndian=\(bigEndian)")
        print("[PTXParser] Found \(blocks.count) blocks. Types: \(typeCounts.map { "0x\(String($0.key, radix:16))×\($0.value)" }.joined(separator: " "))")

        // Session parameters (sample rate, bit depth, TC format, session start)
        let params = PTXBlockDecoder.extractSessionParams(blocks: blocks, data: decoded, bigEndian: bigEndian)
        if params.sampleRate > 0 && session.sampleRate.isEmpty {
            session.sampleRate = "\(params.sampleRate)"
        }
        if params.bitDepth > 0 && session.bitDepth.isEmpty {
            session.bitDepth = "\(params.bitDepth)"
        }
        if !params.tcFormatString.isEmpty && session.tcFormat.isEmpty {
            session.tcFormat = params.tcFormatString
        }
        if session.sessionStart.isEmpty {
            let fps = params.tcFrameRate > 0 ? Int64(params.tcFrameRate) : 30
            let f = params.sessionStartFrames
            session.sessionStart = String(format: "%d:%02d:%02d:%02d",
                f / (fps * 3600), (f / (fps * 60)) % 60, (f / fps) % 60, f % fps)
        }
        print("[PTXParser] Session params: sr=\(params.sampleRate) bd=\(params.bitDepth) fps=\(params.tcFrameRate) start=\(params.sessionStartFrames)")

        // Audio file names from binary (may supplement or replace folder scan)
        let audioFiles = PTXBlockDecoder.extractAudioFiles(blocks: blocks, data: decoded, bigEndian: bigEndian)
        print("[PTXParser] Audio files decoded: \(audioFiles.count)  (first 5: \(audioFiles.prefix(5).map(\.name)))")
        if !audioFiles.isEmpty {
            session.audioFileNames = audioFiles.map(\.name)
            session.audioFileMeta  = audioFiles.map { (fileName: $0.fileName, folderName: $0.folderName) }
        }

        // Plugins from 0x1017 blocks
        let plugins = PTXBlockDecoder.extractPlugins(blocks: blocks, data: decoded)
        print("[PTXParser] Plugins: \(plugins)")
        session.plugins = plugins

        // Per-track plugin assignments (0x102d → 0x2627 OSType matching)
        let trackPlugins = PTXBlockDecoder.extractTrackPlugins(blocks: blocks, data: decoded)
        print("[PTXParser] Track plugins: \(trackPlugins.filter { !$0.value.isEmpty }.map { "\($0.key): \($0.value)" }.sorted())")

        // Memory locations from 0x2077 blocks (sample-accurate positions)
        let memLocs = PTXBlockDecoder.extractMemoryLocations(blocks: blocks, data: decoded)
        if !memLocs.isEmpty {
            session.memoryLocations = memLocs
            print("[PTXParser] Memory locations: \(memLocs.map { "#\($0.number) \"\($0.name)\" @\($0.samplePosition)" })")
        }

        // Clip pool: name + duration from the clip bin (0x2628 blocks)
        let clips = PTXBlockDecoder.extractClips(blocks: blocks, data: decoded, bigEndian: bigEndian)
        let validCount = clips.compactMap { $0 }.count
        print("[PTXParser] Clip pool: \(clips.count) slots, \(validCount) valid (first 3: \(clips.prefix(3).compactMap { $0.map { "\($0.name) len=\($0.lengthSamples)" } }))")

        // Track display info (hidden + folder membership) from the 0x2519 display list block
        let displayInfo = PTXBlockDecoder.extractTrackDisplayInfo(blocks: blocks, data: decoded, bigEndian: bigEndian)

        // Build per-track playlists from 0x1052 blocks (track name + channel count + clip placements)
        let trackPlaylists = PTXBlockDecoder.buildTrackPlaylists(blocks: blocks, data: decoded, bigEndian: bigEndian, displayInfo: displayInfo)
        let playlistSummary = trackPlaylists.map { tp -> String in
            var s = "\(tp.name) ×\(tp.channelCount)ch (\(tp.placements.count) clips) [type:\(tp.trackTypeCode)]"
            if tp.isHidden   { s += " [hidden]" }
            if tp.isInactive { s += " [inactive]" }
            return s
        }
        print("[PTXParser] Track playlists: \(playlistSummary)")

        // Build tracks from playlists (authoritative — includes channel count and clips)
        // Fall back to 0x1014-derived track names if playlists are empty
        var playlistNames = Set<String>()
        if !trackPlaylists.isEmpty {
            session.tracks = trackPlaylists.enumerated().map { i, tp in
                playlistNames.insert(tp.name)
                return PTXTrack(index: i, name: tp.name, type: trackType(from: tp.trackTypeCode),
                                channelCount: tp.channelCount,
                                isHidden: tp.isHidden, isInactive: tp.isInactive, folderName: tp.folderName)
            }
        } else {
            let trackEntries = PTXBlockDecoder.extractTracks(blocks: blocks, data: decoded, bigEndian: bigEndian)
            if !trackEntries.isEmpty {
                session.tracks = trackEntries.map { PTXTrack(index: $0.index, name: $0.name, type: .audio) }
            }
        }

        // Supplement with tracks that have no audio playlists (video, VCA, folder, aux).
        // These are present in the 0x251a display blocks but have no 0x1052 playlist.
        let nextIndex = session.tracks.count
        let extras: [PTXTrack] = displayInfo.types.compactMap { name, typeCode -> PTXTrack? in
            guard !playlistNames.contains(name) else { return nil }
            return PTXTrack(index: nextIndex, name: name, type: trackType(from: typeCode),
                            isHidden: displayInfo.hidden.contains(name),
                            isInactive: displayInfo.inactive.contains(name))
        }
        if !extras.isEmpty {
            session.tracks.append(contentsOf: extras.sorted { $0.name < $1.name })
            // Re-index
            for i in session.tracks.indices { session.tracks[i].index = i }
        }

        // Assign per-track plugins. 0x102d strips are keyed by the ACTIVE PLAYLIST name,
        // which may be "TrackName.dup1" etc. when an alternate playlist is active.
        // Try exact match first, then fall back to the first .dupN variant found.
        for i in session.tracks.indices {
            let name = session.tracks[i].name
            if let plugins = trackPlugins[name] {
                session.tracks[i].plugins = plugins
            } else if let dupKey = trackPlugins.keys.first(where: { $0.hasPrefix(name + ".dup") }) {
                session.tracks[i].plugins = trackPlugins[dupKey] ?? []
            }
        }

        // Build a lookup: audioFileIndex → base name
        let fileNameByIndex: [Int: String] = audioFiles.reduce(into: [:]) { $0[$1.index] = $1.name }

        // Use raw timeline positions (true zero = sample 0, no SMPTE offset subtracted).
        // TODO: add a "Offset to first clip" toggle in Settings.

        // Assign clips to tracks.
        // 0x104f placements with byte[35]==0x01 are hidden sync/dialog references — they are
        // the underlying locked-picture refs that PT keeps but never shows on the timeline.
        // Only byte[35]==0x00 placements are actual timeline clips (music, group, or SFX).
        // Last entry per timeline position wins (handles comp-recorded alternate takes).
        for (i, tp) in trackPlaylists.enumerated() {
            guard i < session.tracks.count else { continue }

            var byPos: [Int64: PTXClip] = [:]

            for p in tp.placements where !p.isHidden {
                let clipEntry = !p.isGroup && p.clipIdx < clips.count ? clips[p.clipIdx] : nil
                let len = p.groupLength ?? clipEntry?.lengthSamples ?? 0
                guard len > 0 else { continue }
                let name = p.groupName ?? clipEntry?.name ?? "Clip \(p.clipIdx)"
                byPos[p.timelineSample] = PTXClip(
                    name: name, startSample: p.timelineSample, lengthSamples: len,
                    sourceFile: clipEntry.flatMap { fileNameByIndex[$0.audioFileIndex] } ?? "",
                    isMuted: p.isMuted
                )
            }

            session.tracks[i].clips = byPos.values.sorted { $0.startSample < $1.startSample }
        }

        // Video clips: extracted from 0x262d/0x2628 blocks with frame→sample conversion.
        // Assign to all video tracks (type == .video) that have no clips yet.
        let videoClips = PTXBlockDecoder.extractVideoClips(
            blocks: blocks, data: decoded, bigEndian: bigEndian,
            sampleRate: params.sampleRate > 0 ? params.sampleRate : 48000,
            frameRate:  params.tcFrameRate > 0 ? params.tcFrameRate : 24
        )
        print("[PTXParser] Video clips: \(videoClips.count)")
        if !videoClips.isEmpty {
            for i in session.tracks.indices where session.tracks[i].type == .video && session.tracks[i].clips.isEmpty {
                session.tracks[i].clips = videoClips
            }
        }
    }

    // MARK: - Track type mapping

    private static func trackType(from code: UInt16) -> PTXTrackType {
        switch code {
        case 0x00: return .audio
        case 0x02: return .aux
        case 0x08: return .video
        case 0x09: return .vca
        case 0x0b: return .folder
        default:   return .unknown
        }
    }

    // MARK: - Clip log
    // Writes a human-readable clip report to /tmp/ptpeep_clips.log.
    // Call after augment() if PT is connected so sample rate is populated.

    static func writeClipLog(session: PTXSession, sessionURL: URL) {
        let sr = Double(session.sampleRate) ?? 48000.0
        let fps = session.frameRate
        let srLabel = session.sampleRate.isEmpty ? "48000 (assumed)" : "\(session.sampleRate)"
        let audioTracks = session.tracks.filter { $0.type == .audio }
        let totalClips  = audioTracks.reduce(0) { $0 + $1.clips.count }

        var lines: [String] = []

        let stamp = ISO8601DateFormatter().string(from: Date())
        lines.append("=== \(session.sessionName)  |  \(stamp) ===")
        lines.append("Sample Rate : \(srLabel) Hz")
        lines.append("Tracks      : \(audioTracks.count)")
        lines.append("Total Clips : \(totalClips)")
        lines.append("")

        for track in session.tracks {
            let tag     = "[\(track.channelFormat)]"
            let divider = String(repeating: "─", count: max(0, 60 - track.name.count - tag.count - 5))
            lines.append("── \(track.name) \(tag) \(divider) (\(track.clips.count) clips)")
            if track.clips.isEmpty {
                lines.append("   (no clips)")
            } else {
                for (i, clip) in track.clips.enumerated() {
                    let start    = formatTC(samples: clip.startSample, sr: sr, fps: fps)
                    let len      = formatTC(samples: clip.lengthSamples, sr: sr, fps: fps)
                    let file     = clip.sourceFile.isEmpty ? "—" : clip.sourceFile
                    let namePad  = clip.name.padding(toLength: 50, withPad: " ", startingAt: 0)
                    let startPad = start.padding(toLength: 12, withPad: " ", startingAt: 0)
                    let lenPad   = len.padding(toLength: 12, withPad: " ", startingAt: 0)
                    let num      = String(format: "%02d", i + 1)
                    let muted    = clip.isMuted ? "  Muted" : ""
                    lines.append("  [\(num)] \(namePad)  start=\(startPad)  len=\(lenPad)  file=\(file)  [\(clip.startSample)]\(muted)")
                }
            }
            lines.append("")
        }

        let text = lines.joined(separator: "\n")
        let logURL = sessionURL.deletingPathExtension().appendingPathExtension("log")
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
        print("[PTXParser] Clip log written to \(logURL.path)")
    }

    /// Format a sample count as H:MM:SS:FF
    private static func formatTC(samples: Int64, sr: Double, fps: Double) -> String {
        guard sr > 0, fps > 0, samples >= 0 else { return "—" }
        let totalFrames = Int64((Double(samples) / sr * fps).rounded())
        let fr  = Int64(fps.rounded())
        let f   = totalFrames % fr
        let sec = (totalFrames / fr) % 60
        let min = (totalFrames / fr / 60) % 60
        let hr  = totalFrames / fr / 3600
        return String(format: "%d:%02d:%02d:%02d", hr, min, sec, f)
    }

    // MARK: - PT-format text export
    // Generates a text file matching Pro Tools' "Export Session Info as Text" format.
    // Known gaps vs PT export: no per-channel stereo split, no fade/crossfade clips,
    // no BWF TIMESTAMP values, no full file paths (uses session folder), no plugin detail.

    static func writeTextExport(session: PTXSession, sessionURL: URL) {
        let sr  = Double(session.sampleRate) ?? 48000.0
        let fps = session.frameRate

        // Format samples as HH:MM:SS:FF.ss (14 chars, subframes = hundredths of frame)
        func tc(_ samples: Int64) -> String {
            guard sr > 0, fps > 0, samples >= 0 else { return "00:00:00:00.00" }
            let exactFrames = Double(samples) / sr * fps
            let intFrames   = Int64(exactFrames)
            let sub = Int(min(99, max(0, Int(((exactFrames - Double(intFrames)) * 100).rounded()))))
            let fr  = max(1, Int64(fps.rounded()))
            let f   = intFrames % fr
            let sec = (intFrames / fr) % 60
            let min = (intFrames / fr / 60) % 60
            let hr  = intFrames / fr / 3600
            return String(format: "%02d:%02d:%02d:%02d.%02d", hr, min, sec, f, sub)
        }

        // Pad string to at least `n` characters
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : s.padding(toLength: n, withPad: " ", startingAt: 0)
        }

        // Reformat stored "H:MM:SS:FF" sessionStart → "HH:MM:SS:FF.ss"
        func sessionStartTC() -> String {
            let parts = session.sessionStart.components(separatedBy: ":")
            guard parts.count == 4,
                  let h = Int(parts[0]), let m = Int(parts[1]),
                  let s = Int(parts[2]), let f = Int(parts[3]) else {
                return "00:00:00:00.00"
            }
            return String(format: "%02d:%02d:%02d:%02d.00", h, m, s, f)
        }

        // TC format label matching PT's convention
        func tcFormatLabel() -> String {
            let base = session.tcFormat.components(separatedBy: " ").first ?? session.tcFormat
            let isDF = session.tcFormat.uppercased().contains("DF")
            switch base {
            case "23.976", "23.98": return "23.976 Frame"
            case "24":              return "24 Frame"
            case "25":              return "25 Frame"
            case "29.97":           return isDF ? "29.97 Frame (Drop)" : "29.97 Frame (Non-Drop)"
            case "30":              return "30 Frame"
            case "47.952":          return "47.952 Frame"
            case "48":              return "48 Frame"
            case "50":              return "50 Frame"
            case "59.94":           return "59.94 Frame"
            case "60":              return "60 Frame"
            default:                return session.tcFormat.isEmpty ? "30 Frame" : "\(session.tcFormat) Frame"
            }
        }

        let audioTracks = session.tracks.filter { $0.type == .audio }
        let allClips    = audioTracks.flatMap(\.clips)
        var lines: [String] = []

        // ── Session header ────────────────────────────────────────────────────────
        let srStr = session.sampleRate.isEmpty ? "48000" : session.sampleRate
        let bdStr = session.bitDepth.isEmpty   ? "24"    : session.bitDepth
        lines.append("SESSION NAME:\t\(session.sessionName)")
        lines.append("SAMPLE RATE:\t\(srStr).000000")
        lines.append("BIT DEPTH:\t\(bdStr)-bit")
        lines.append("SESSION START TIMECODE:\t\(sessionStartTC())")
        lines.append("TIMECODE FORMAT:\t\(tcFormatLabel())")
        lines.append("# OF AUDIO TRACKS:\t\(audioTracks.count)")
        lines.append("# OF AUDIO CLIPS:\t\(allClips.count)")
        lines.append("# OF AUDIO FILES:\t\(session.audioFileNames.count)")
        lines.append("")
        lines.append("")

        // ── Online files ──────────────────────────────────────────────────────────
        let sessionDir = sessionURL.deletingLastPathComponent().path
        let macBase    = "Macintosh HD" + sessionDir.replacingOccurrences(of: "/", with: ":") + ":Audio Files:"
        lines.append("O N L I N E  F I L E S  I N  S E S S I O N")
        lines.append("Filename\t" + pad("", 108) + "Location")
        for name in session.audioFileNames {
            lines.append("\(pad(name + ".wav", 112))\t\(macBase)")
        }
        lines.append("")
        lines.append("")

        // ── Offline files ─────────────────────────────────────────────────────────
        lines.append("O F F L I N E  F I L E S  I N  S E S S I O N")
        lines.append("Filename\t" + pad("", 108) + "Location")
        lines.append("")
        lines.append("")

        // ── Online clips ──────────────────────────────────────────────────────────
        lines.append("O N L I N E  C L I P S  I N  S E S S I O N")
        lines.append("CLIP NAME\t" + pad("", 103) + "Source File")
        var seenClips = Set<String>()
        for clip in allClips {
            let key = clip.name + "|\(clip.sourceFile)"
            guard !seenClips.contains(key) else { continue }
            seenClips.insert(key)
            let src = clip.sourceFile.isEmpty ? "" : clip.sourceFile + ".wav"
            lines.append("\(pad(clip.name, 112))\t\(src)")
        }
        lines.append("")
        lines.append("")

        // ── Plug-ins ──────────────────────────────────────────────────────────────
        lines.append("P L U G - I N S  L I S T I N G")
        lines.append("MANUFACTURER            \tPLUG-IN NAME            \tVERSION         \tFORMAT          \tSTEMS                   \tNUMBER OF INSTANCES")
        for plugin in session.plugins {
            lines.append(pad("", 24) + "\t" + pad(plugin, 24) + "\t" + pad("", 16) + "\t" + pad("", 16) + "\t" + pad("", 24) + "\t")
        }
        lines.append("")
        lines.append("")

        // ── Track listing ─────────────────────────────────────────────────────────
        let clipHeader = "CHANNEL \tEVENT   \tCLIP NAME                     \tSTART TIME    \tEND TIME      \tDURATION      \tTIMESTAMP         \tSTATE"
        lines.append("T R A C K  L I S T I N G")
        for track in session.tracks where track.type == .audio {
            let chLabel = track.channelCount > 1 ? " (\(track.channelFormat))" : ""
            lines.append("TRACK NAME:\t\(track.name)\(chLabel)")
            lines.append("COMMENTS:\t")
            lines.append("USER DELAY:\t0 Samples")
            var stateFlags: [String] = []
            if track.isHidden   { stateFlags.append("Hidden") }
            if track.isInactive { stateFlags.append("Inactive") }
            lines.append("STATE: \(stateFlags.joined(separator: " ")) ")
            let pluginList = track.plugins.isEmpty
                ? ""
                : "\t" + track.plugins.map { $0 + " (mono)" }.joined(separator: "\t")
            lines.append("PLUG-INS: \(pluginList)")
            lines.append(clipHeader)
            // List as channel 1 only (no per-channel stereo split — known gap)
            for (i, clip) in track.clips.enumerated() {
                let startT = tc(clip.startSample)
                let endT   = tc(clip.startSample + clip.lengthSamples)
                let durT   = tc(clip.lengthSamples)
                let state  = clip.isMuted ? "Muted" : "Unmuted"
                lines.append("1       \t\(pad(String(i+1), 8))\t\(pad(clip.name, 30))\t\(startT)\t\(endT)\t\(durT)\t    00:00:00:00.00\t\(state)")
            }
            lines.append("")
            lines.append("")
        }

        // ── Markers listing ───────────────────────────────────────────────────────
        lines.append("M A R K E R S  L I S T I N G")
        lines.append("#   \tLOCATION     \tTIME REFERENCE    \tUNITS    \tNAME                             \tTRACK NAME                       \tTRACK TYPE   \tCOMMENTS")
        for loc in session.memoryLocations where loc.samplePosition >= 0 {
            let locTC   = tc(loc.samplePosition)
            let sampStr = String(loc.samplePosition)
            lines.append("\(pad(String(loc.number), 4))\t\(locTC)\t\(pad(sampStr, 18))\tSamples  \t\(pad(loc.name, 33))\t\(pad("Markers", 33))\tRuler                            \t")
        }

        let text = lines.joined(separator: "\n")
        let outURL = sessionURL.deletingPathExtension().appendingPathExtension("ptpeep.txt")
        try? text.write(to: outURL, atomically: true, encoding: .utf8)
        print("[PTXParser] Text export written to \(outURL.path)")
    }

    // MARK: - EDL export (CMX 3600)
    // Generates a .edl file for the specified tracks (or all audio tracks if nil).
    // Format: CMX 3600 with comment lines for clip name, source file, and plugins.
    // Source TC uses clip sourceFile position; TIMESTAMP is unavailable without BWF.

    @discardableResult
    static func writeEDL(session: PTXSession, sessionURL: URL, trackNames: [String]? = nil) -> URL? {
        let sr  = Double(session.sampleRate) ?? 48000.0
        let fps = session.frameRate

        func tc(_ samples: Int64) -> String {
            guard sr > 0, fps > 0, samples >= 0 else { return "00:00:00:00" }
            let totalFrames = Int64((Double(samples) / sr * fps).rounded())
            let fr  = max(1, Int64(fps.rounded()))
            let f   = totalFrames % fr
            let sec = (totalFrames / fr) % 60
            let min = (totalFrames / fr / 60) % 60
            let hr  = totalFrames / fr / 3600
            return String(format: "%02d:%02d:%02d:%02d", hr, min, sec, f)
        }

        // CMX 3600 drop-frame flag
        let isDrop   = session.tcFormat.uppercased().contains("DF")
        let fcm      = isDrop ? "DROP FRAME" : "NON-DROP FRAME"

        // Source reel name: abbreviated audio file (≤8 chars, no spaces) or "AX"
        func reelName(_ sourceFile: String) -> String {
            let stripped = sourceFile
                .replacingOccurrences(of: " ", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            return String(stripped.prefix(8)).isEmpty ? "AX" : String(stripped.prefix(8))
        }

        var selectedTracks = session.tracks.filter { $0.type == .audio }
        if let names = trackNames {
            selectedTracks = selectedTracks.filter { names.contains($0.name) }
        }

        var lines: [String] = []
        lines.append("TITLE: \(session.sessionName)")
        lines.append("FCM: \(fcm)")
        lines.append("")

        var eventNum = 1
        for track in selectedTracks {
            guard !track.clips.isEmpty else { continue }
            lines.append("* TRACK: \(track.name)")
            if !track.plugins.isEmpty {
                lines.append("* PLUGINS: \(track.plugins.joined(separator: ", "))")
            }

            for clip in track.clips {
                let reel   = reelName(clip.sourceFile)
                // Channel designation: A = mono, AA = stereo, B = aux
                let chDes  = track.channelCount > 1 ? "AA" : "A "
                let srcIn  = tc(0)          // no BWF source offset available
                let srcOut = tc(clip.lengthSamples)
                let recIn  = tc(clip.startSample)
                let recOut = tc(clip.startSample + clip.lengthSamples)
                let mute   = clip.isMuted ? " (MUTED)" : ""

                // CMX 3600 event line: EVENT  REEL  CHANS  TYPE  SRC_IN  SRC_OUT  REC_IN  REC_OUT
                let reelPad = reel.padding(toLength: 8, withPad: " ", startingAt: 0)
                lines.append("\(String(format: "%03d", eventNum))  \(reelPad) \(chDes)    C        \(srcIn) \(srcOut) \(recIn) \(recOut)")
                lines.append("* FROM CLIP NAME: \(clip.name)\(mute)")
                if !clip.sourceFile.isEmpty {
                    lines.append("* SOURCE FILE: \(clip.sourceFile).wav")
                }
                lines.append("")
                eventNum += 1
            }
        }

        let text   = lines.joined(separator: "\n")
        let suffix = (trackNames != nil) ? ".selected" : ""
        let outURL = sessionURL.deletingPathExtension().appendingPathExtension("\(suffix)edl")
        do {
            try text.write(to: outURL, atomically: true, encoding: .utf8)
            print("[PTXParser] EDL written to \(outURL.path)  (\(eventNum - 1) events)")
            return outURL
        } catch {
            print("[PTXParser] EDL write failed: \(error)")
            return nil
        }
    }

    // MARK: - Resolve audio files
    // Locate actual WAV/AIFF files in the session's "Audio Files" folder.

    static func resolveAudioFiles(session: inout PTXSession, sessionURL: URL) {
        let sessionDir = sessionURL.deletingLastPathComponent()
        let fm = FileManager.default

        // Fallback: scan Audio Files folder
        let fallbackPaths = scanAudioFilesFolder(sessionURL: sessionURL)

        var resolved: [ResolvedAudioFile] = []
        for (i, name) in session.audioFileNames.enumerated() {
            var url: URL? = nil
            if i < session.audioFileMeta.count {
                let meta = session.audioFileMeta[i]
                let candidate = sessionDir
                    .appendingPathComponent(meta.folderName)
                    .appendingPathComponent(meta.fileName)
                if fm.fileExists(atPath: candidate.path) { url = candidate }
            }
            if url == nil { url = fallbackPaths[name] }
            resolved.append(ResolvedAudioFile(name: name, url: url))
        }
        session.resolvedAudioFiles = resolved
    }

    private static func scanAudioFilesFolder(sessionURL: URL) -> [String: URL] {
        let audioExts: Set<String> = ["wav", "aif", "aiff", "bwf", "w64", "rf64", "sd2", "mp3"]
        let root = sessionURL.deletingLastPathComponent().appendingPathComponent("Audio Files")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard audioExts.contains(url.pathExtension.lowercased()) else { continue }
            let baseName = url.deletingPathExtension().lastPathComponent
            if result[baseName] == nil { result[baseName] = url }
        }
        return result
    }
}

// MARK: - BinaryScanner

private final class BinaryScanner {
    let data: Data

    init(data: Data) { self.data = data }

    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return data.loadLE(UInt32.self, at: offset)
    }

    /// Read a 4-byte LE length-prefixed UTF-8 string at `offset`.
    func readLEString(at offset: Int) -> String? {
        guard let slen = readUInt32LE(at: offset),
              slen >= 1, slen <= 512,
              offset + 4 + Int(slen) <= data.count else { return nil }
        let slice = data[offset+4 ..< offset+4+Int(slen)]
        guard slice.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(bytes: slice, encoding: .utf8)
    }

    /// Find first occurrence of a literal ASCII string within searchLimit bytes.
    func findString(_ s: String, searchLimit: Int = Int.max) -> Int? {
        guard let needle = s.data(using: .utf8) else { return nil }
        let limit = min(searchLimit, data.count - needle.count)
        for i in 0..<limit {
            if data[i ..< i + needle.count] == needle {
                return i
            }
        }
        return nil
    }
}

// MARK: - Data extension

private extension Data {
    func loadLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(self[offset + i]) << (i * 8)
        }
        return value
    }
}
