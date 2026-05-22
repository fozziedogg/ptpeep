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
        let pool = region.resolvedPool
        try await Task.detached(priority: .userInitiated) {
            for (segIdx, segment) in segments.enumerated() {
                for (clip, url) in segment.clips {
                    let srcStart  = Int32(clamping: clip.sourceOffset)
                    let srcStop   = Int32(clamping: clip.sourceOffset + clip.lengthSamples)
                    let offset    = Int32(clamping: clip.startSample - regStart)
                    let channels  = PTSLSessionInfo.multiMonoChannels(of: url, pool: pool)
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

    /// Returns (url, streamIndex) for every channel file of a multi-mono group,
    /// sorted by stream index.  For a mono or unrecognised file returns [(url, 1)].
    ///
    /// Strategy: strip the channel suffix from the file's stem to get a base name,
    /// then find all files (in the pool or same directory) whose stem strips to the
    /// same base.  This handles companions in any subdirectory without needing to
    /// guess stem-marker conventions.
    static func multiMonoChannels(of url: URL, pool: [URL] = []) -> [(url: URL, stream: Int16)] {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        let dir  = url.deletingLastPathComponent()

        // Identify this file's channel suffix and derive the shared base name.
        guard let (matchedSuffix, selfStream) = ptChannelSuffixes.first(where: { stem.hasSuffix($0.suffix) }) else {
            AppLog.shared.log("[AESpot] multiMono: no suffix matched, returning mono for '\(stem)'")
            return [(url, 1)]
        }
        let base = String(stem.dropLast(matchedSuffix.count))
        AppLog.shared.log("[AESpot] multiMono: base='\(base)' suffix='\(matchedSuffix)' stream=\(selfStream)")

        // ── 1. Pool search (finds companions in any subdirectory) ─────────────
        // Two-pass when the stem has a _L-/_R- marker:
        //   Pass A: seed with self + search for SWAPPED-base companions only.
        //           (e.g. "Foo_L-Bar.L" → look for "Foo_R-Bar.*")
        //           Correct for sessions where the R file has a different stem marker.
        //   Pass B: search for SAME-base companions.
        //           (e.g. "Foo_L-Bar.L" + "Foo_L-Bar.R")
        //           Correct for sessions where both channels share the same stem.
        // Without a _L-/_R- marker, only a single same-base pass is needed.
        if !pool.isEmpty {
            // Build swapped-base variants (empty if no marker present).
            var swappedBases = Set<String>()
            for (from, to) in [("_L-", "_R-"), ("_R-", "_L-")] {
                if base.contains(from) {
                    swappedBases.insert(base.replacingOccurrences(of: from, with: to))
                }
            }

            func poolScan(bases: Set<String>, seed: [(url: URL, stream: Int16)]) -> [(url: URL, stream: Int16)] {
                var found = seed
                var seenStreams = Set(seed.map { $0.stream })
                for poolURL in pool {
                    let poolStem = poolURL.deletingPathExtension().lastPathComponent
                    for (s, str) in ptChannelSuffixes {
                        guard !seenStreams.contains(str), poolStem.hasSuffix(s) else { continue }
                        if bases.contains(String(poolStem.dropLast(s.count))) {
                            AppLog.shared.log("[AESpot] multiMono: pool '\(poolURL.lastPathComponent)' Strm=\(str)")
                            found.append((poolURL, str))
                            seenStreams.insert(str)
                            break
                        }
                    }
                }
                return found
            }

            // Pass A: swapped-base (only when marker present), seeded with self.
            if !swappedBases.isEmpty {
                let fromSwapped = poolScan(bases: swappedBases, seed: [(url, selfStream)])
                if fromSwapped.count > 1 {
                    return fromSwapped.sorted { $0.stream < $1.stream }
                }
            }

            // Pass B: same-base (all stems).
            let fromSame = poolScan(bases: Set([base]), seed: [])
            if fromSame.count > 1 {
                return fromSame.sorted { $0.stream < $1.stream }
            }
        }

        // ── 2. Same-directory scan (pool empty or companion not in pool) ──────
        var found: [(url: URL, stream: Int16)] = [(url, selfStream)]
        var seenStreams: Set<Int16> = [selfStream]
        for (s, str) in ptChannelSuffixes {
            guard !seenStreams.contains(str) else { continue }
            let name      = base + s + (ext.isEmpty ? "" : "." + ext)
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                AppLog.shared.log("[AESpot] multiMono: dir '\(name)' Strm=\(str)")
                found.append((candidate, str))
                seenStreams.insert(str)
            }
        }
        if found.count > 1 {
            return found.sorted { $0.stream < $1.stream }
        }

        AppLog.shared.log("[AESpot] multiMono: no companions found, returning Strm=\(selfStream)")
        return [(url, selfStream)]
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
