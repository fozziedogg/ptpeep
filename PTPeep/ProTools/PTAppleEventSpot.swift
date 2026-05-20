import AppKit
import AVFoundation
import Carbon
import Foundation

// MARK: - Apple Event "Spot to Region" for Pro Tools
//
// Sends the classic 'Sd2a'/'SRgn' AppleEvent that Pro Tools has accepted since
// PT 5.1.  No PTSL/gRPC required.
//
// Key parameters (from the Avid RegionSpotter SDK, 2005):
//   Trak = -99       → spot onto the currently selected track(s)
//   TkOf             → track offset (0 = selected, 1 = next track down, …)
//   SMSt             → sample offset *from the current PT edit-cursor position*
//   Rgn.Star / Stop  → source in/out within the audio file;
//                      Star=0 / Stop=fileLength exposes full pre- and post-roll handles

extension PTSLSessionInfo {

    /// Spots every clip in `region` into Pro Tools via Apple Events.
    ///
    /// The region start aligns to the PT edit cursor; all clips are placed at
    /// their relative offset from that cursor so spacing is preserved.
    /// Each track segment uses TkOf to land on successive tracks below the
    /// selected one.  Full source-file handles are exposed.
    func spotRegionViaAppleEvent(_ region: PlayRegion) async throws {
        let segments = region.segments
        let regStart = region.startSample
        let totalClips = segments.reduce(0) { $0 + $1.clips.count }
        AppLog.shared.log("[AESpot] BEGIN \(segments.count) segment(s), \(totalClips) clip(s), regStart=\(regStart)")
        // AESend is synchronous — run all sends off the main thread.
        try await Task.detached(priority: .userInitiated) {
            for (segIdx, segment) in segments.enumerated() {
                for (clip, url) in segment.clips {
                    let srcStart  = Int32(clamping: clip.sourceOffset)
                    let srcStop   = Int32(clamping: clip.sourceOffset + clip.lengthSamples)
                    let offset    = Int32(clamping: clip.startSample - regStart)
                    let channels  = PTSLSessionInfo.multiMonoChannels(of: url)
                    for (chURL, stream) in channels {
                        AppLog.shared.log("[AESpot] clip='\(clip.name)' track+\(segIdx) Strm=\(stream) SMSt=\(offset) Star=\(srcStart) Stop=\(srcStop) url=\(chURL.lastPathComponent)")
                        try PTSLSessionInfo.aeSendSpot(
                            url:          chURL,
                            srcStart:     srcStart,
                            srcStop:      srcStop,
                            name:         clip.name,
                            trackOffset:  Int16(segIdx),
                            sampleOffset: offset,
                            stream:       stream
                        )
                    }
                }
            }
        }.value
        AppLog.shared.log("[AESpot] END — all sends complete")
    }

    // MARK: - Private implementation

    private static func aeFileLength(url: URL, fallback: Int64) -> Int64 {
        (try? AVAudioFile(forReading: url)).map { Int64($0.length) } ?? fallback
    }

    /// Sends one 'Sd2a'/'SRgn' AppleEvent to Pro Tools.
    ///
    /// - Parameters:
    ///   - url:          Absolute path to the audio file.
    ///   - srcStart:     First sample of the file to include in the region (0 = expose pre-roll).
    ///   - srcStop:      Last sample of the file to include (fileLength = expose post-roll).
    ///   - name:         Region name shown in PT.
    ///   - trackOffset:  Track offset from the PT selection (0 = selected track, 1 = one below, …).
    ///   - sampleOffset: Samples from the current PT edit-cursor / selection start.
    ///   - stream:       Playlist within a multichannel track (1 = mono or left channel).
    private static func aeSendSpot(
        url:          URL,
        srcStart:     Int32,
        srcStop:      Int32,
        name:         String,
        trackOffset:  Int16,
        sampleOffset: Int32,
        stream:       Int16
    ) throws {
        // ── Target: Pro Tools by kernel PID (most reliable across macOS versions) ──
        guard let ptApp = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.avid.ProTools").first
        else { throw PTSLError.commandFailed("AESpot: Pro Tools is not running") }
        var pid = ptApp.processIdentifier
        guard let targetDesc = NSAppleEventDescriptor(
            descriptorType: DescType(typeKernelProcessID),
            bytes: &pid,
            length: MemoryLayout<pid_t>.size
        ) else { throw PTSLError.commandFailed("AESpot: bad target descriptor") }

        // ── Build the AppleEvent ──────────────────────────────────────────────
        let ae = NSAppleEventDescriptor(
            eventClass: aeCC("Sd2a"),   // Digidesign Audio Suite
            eventID:    aeCC("SRgn"),   // Spot Region
            targetDescriptor: targetDesc,
            returnID:   AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        // FILE — audio file as a typeFileURL descriptor
        ae.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: aeCC("FILE"))

        // Trak = -99 → spot to the currently selected track
        ae.setParam(ae16(-99),          forKeyword: aeCC("Trak"))
        // FFrm — frame format (PT parses then ignores)
        ae.setParam(ae16(1),            forKeyword: aeCC("FFrm"))
        // TkOf — track offset from selection
        ae.setParam(ae16(trackOffset),  forKeyword: aeCC("TkOf"))
        // SMSt — sample offset from PT edit cursor / selection start
        ae.setParam(ae32(sampleOffset), forKeyword: aeCC("SMSt"))
        // Strm — playlist/stream index within multichannel track
        ae.setParam(ae16(stream),       forKeyword: aeCC("Strm"))

        // ── Rgn record: Star, Stop, Name ──────────────────────────────────────
        let rgn = NSAppleEventDescriptor.record()
        rgn.setDescriptor(ae32(srcStart), forKeyword: aeCC("Star"))
        rgn.setDescriptor(ae32(srcStop),  forKeyword: aeCC("Stop"))

        // Pascal string: first byte is length, up to 255 macOSRoman chars, 256-byte buffer total.
        var nameEncoded = name.data(using: .macOSRoman) ?? Data(name.utf8)
        if nameEncoded.count > 255 { nameEncoded = nameEncoded.prefix(255) }
        var pascal = Data([UInt8(nameEncoded.count)]) + nameEncoded
        pascal += Data(repeating: 0, count: max(0, 256 - pascal.count))
        let nameDesc = pascal.withUnsafeBytes {
            NSAppleEventDescriptor(descriptorType: DescType(typeChar),
                                   bytes: $0.baseAddress, length: pascal.count)
        } ?? NSAppleEventDescriptor(string: name)
        rgn.setDescriptor(nameDesc, forKeyword: aeCC("Name"))

        ae.setParam(rgn, forKeyword: aeCC("Rgn "))

        // ── Send — fire and forget ────────────────────────────────────────────
        AppLog.shared.log("[AESpot] Sending Sd2a/SRgn → PTul  Trak=-99 TkOf=\(trackOffset) SMSt=\(sampleOffset) Star=\(srcStart) Stop=\(srcStop)")
        var reply = AEDesc()
        let err = AESend(ae.aeDesc,
                         &reply,
                         AESendMode(kAEWaitReply | kAECanInteract),
                         AESendPriority(kAENormalPriority),
                         Int32(kAEDefaultTimeout), nil, nil)
        // Log any error string PT put in the reply
        let replyDesc = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        if let errStr = replyDesc.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue {
            AppLog.shared.log("[AESpot] PT reply errorString: \(errStr)")
        }
        if let errNum = replyDesc.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value {
            AppLog.shared.log("[AESpot] PT reply errorNumber: \(errNum)")
        }
        if err == noErr {
            AppLog.shared.log("[AESpot] AESend OK")
        } else {
            AppLog.shared.log("[AESpot] AESend FAILED OSErr=\(err)")
            throw PTSLError.commandFailed("AESend returned OSErr \(err)")
        }
    }

    // MARK: - Multichannel helpers

    // PT multi-mono channel suffixes in stream order.
    // Covers stereo, LCR, LCRS, quad, 5.1, 7.1 SDDS, 7.1 DTS variants.
    private static let ptChannelSuffixes: [(suffix: String, stream: Int16)] = [
        (".L",   1), (".R",    2), (".C",   3), (".LFE",  4),
        (".Ls",  5), (".Rs",   6), (".Lss", 7), (".Rss",  8),
        // Alternate spellings PT uses in different versions
        (".Lfe", 4), (".Lsr",  7), (".Rsr", 8),
        (".Lc",  2), (".Rc",   4),   // 7.1 SDDS centre pairs
        (".S",   4),                  // LCRS surround
        (".M",   1),                  // mono alias
    ]

    /// Returns (url, streamIndex) for every channel file of a multi-mono group found on disk,
    /// sorted by stream index.  For a mono or unrecognised file returns [(url, 1)].
    static func multiMonoChannels(of url: URL) -> [(url: URL, stream: Int16)] {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        let dir  = url.deletingLastPathComponent()
        AppLog.shared.log("[AESpot] multiMono: stem='\(stem)' ext='\(ext)'")

        // ── .Suffix style (.L, .R, .C, .LFE, .Ls, .Rs, …) ──────────────────
        for (suffix, _) in ptChannelSuffixes where stem.hasSuffix(suffix) {
            let base = String(stem.dropLast(suffix.count))
            AppLog.shared.log("[AESpot] multiMono: matched suffix '\(suffix)', base='\(base)'")
            var found: [(url: URL, stream: Int16)] = []
            var seenStreams = Set<Int16>()
            for (otherSuffix, stream) in ptChannelSuffixes {
                guard !seenStreams.contains(stream) else { continue }
                let name      = base + otherSuffix + (ext.isEmpty ? "" : "." + ext)
                let candidate = dir.appendingPathComponent(name)
                let exists    = FileManager.default.fileExists(atPath: candidate.path)
                AppLog.shared.log("[AESpot] multiMono:   check '\(name)' → \(exists ? "FOUND" : "missing")")
                if exists {
                    found.append((candidate, stream))
                    seenStreams.insert(stream)
                }
            }
            if found.count > 1 {
                AppLog.shared.log("[AESpot] multiMono: suffix path returning \(found.count) channel(s)")
                return found.sorted { $0.stream < $1.stream }
            }
            // Only the original file found — fall through to stem-marker check
            // in case this file also carries a _L-/_R- marker (e.g.
            // "Sound_L-Var.L.wav" paired with "Sound_R-Var.R.wav").
            AppLog.shared.log("[AESpot] multiMono: suffix match found no companions, trying stem-marker")
            break
        }

        // ── _L- / _R- stem-marker style (PT stereo multi-mono) ───────────────
        // Also handles files that carry both a suffix (.L/.R) AND a stem marker
        // (_L-/_R-), e.g. "Sound_L-Var.L.wav" paired with "Sound_R-Var.R.wav".
        let stemMarkers: [(from: String, stream: Int16, companions: [(String, Int16)])] = [
            ("_L-", 1, [("_R-", 2)]),
            ("_R-", 2, [("_L-", 1)]),
        ]
        for marker in stemMarkers {
            // Search in the full stem (may include a .L/.R suffix still attached).
            guard let range = stem.range(of: marker.from) else { continue }
            AppLog.shared.log("[AESpot] multiMono: matched stem-marker '\(marker.from)'")
            var result: [(url: URL, stream: Int16)] = [(url, marker.stream)]
            for (otherMarker, otherStream) in marker.companions {
                // Try every channel suffix (or no suffix) for the companion.
                let suffixesToTry: [String] = ptChannelSuffixes.map { $0.suffix } + [""]
                var companionFound = false
                for companionSuffix in suffixesToTry {
                    // Build companion stem: swap marker, replace trailing channel suffix if present.
                    var s = stem
                    s.replaceSubrange(range, with: otherMarker)
                    // If the current stem ends with a channel suffix, replace it with the companion's.
                    for (thisSuffix, _) in ptChannelSuffixes where s.hasSuffix(thisSuffix) {
                        s = String(s.dropLast(thisSuffix.count)) + companionSuffix
                        break
                    }
                    let name = s + (ext.isEmpty ? "" : "." + ext)
                    let candidate = dir.appendingPathComponent(name)
                    let exists = FileManager.default.fileExists(atPath: candidate.path)
                    AppLog.shared.log("[AESpot] multiMono:   check companion '\(name)' → \(exists ? "FOUND" : "missing")")
                    if exists {
                        result.append((candidate, otherStream))
                        companionFound = true
                        break
                    }
                }
                if !companionFound {
                    AppLog.shared.log("[AESpot] multiMono:   companion for '\(otherMarker)' not found on disk")
                }
            }
            AppLog.shared.log("[AESpot] multiMono: stem-marker path returning \(result.count) channel(s)")
            return result.sorted { $0.stream < $1.stream }
        }

        AppLog.shared.log("[AESpot] multiMono: no multi-mono pattern matched, returning mono")
        return [(url, 1)]
    }

    // MARK: - FourCharCode helpers

    /// Converts a 4-character ASCII string to a big-endian FourCharCode (OSType).
    private static func aeCC(_ s: String) -> FourCharCode {
        s.unicodeScalars.prefix(4).reduce(into: FourCharCode(0)) { acc, c in
            acc = (acc << 8) | FourCharCode(c.value)
        }
    }

    /// Wraps an Int16 in a typeSInt16 ('shor') AEDesc.
    private static func ae16(_ v: Int16) -> NSAppleEventDescriptor {
        var val = v
        return NSAppleEventDescriptor(
            descriptorType: aeCC("shor"),   // typeSInt16
            bytes: &val, length: 2
        ) ?? .null()
    }

    /// Wraps an Int32 in a typeSInt32 ('long') AEDesc.
    private static func ae32(_ v: Int32) -> NSAppleEventDescriptor {
        var val = v
        return NSAppleEventDescriptor(
            descriptorType: aeCC("long"),   // typeSInt32
            bytes: &val, length: 4
        ) ?? .null()
    }
}
