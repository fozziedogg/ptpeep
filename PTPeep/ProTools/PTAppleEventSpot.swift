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
            // Build stem→URL lookup once so per-channel file resolution is O(1).
            var poolByName: [String: URL] = [:]
            for u in pool {
                let stem = u.deletingPathExtension().lastPathComponent
                if poolByName[stem] == nil { poolByName[stem] = u }
            }
            // Cache per-clip channel lists so repeated clips (same source file) resolve once.
            var channelCache: [URL: [(url: URL, stream: Int16)]] = [:]
            for (segIdx, segment) in segments.enumerated() {
                for (clip, url) in segment.clips {
                    let srcStart  = Int32(clamping: clip.sourceOffset)
                    let srcStop   = Int32(clamping: clip.sourceOffset + clip.lengthSamples)
                    let offset    = Int32(clamping: clip.startSample - regStart)
                    let channels: [(url: URL, stream: Int16)]
                    if let cached = channelCache[url] {
                        channels = cached
                    } else {
                        var resolved: [(url: URL, stream: Int16)] = clip.channelFiles.enumerated().compactMap { i, name in
                            guard let u = poolByName[name] else { return nil }
                            return (u, Int16(i + 1))
                        }
                        // Interleaved multichannel: all channel entries point to the same file.
                        // Send just one event (Strm=1) — PT reads all channels from the interleaved
                        // file automatically. Sending N identical URLs with Strm=1…N only spots the
                        // first channel into every stream.
                        if Set(resolved.map(\.url)).count == 1, resolved.count > 1 {
                            resolved = [(resolved[0].url, 1)]
                        }
                        AppLog.shared.log("[AESpot] channels: \(resolved.map { "Strm\($0.stream):\($0.url.lastPathComponent)" })")
                        channelCache[url] = resolved
                        channels = resolved
                    }
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
        // Return focus to Pro Tools so the user can interact with placed clips immediately.
        if let ptApp = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.avid.ProTools").first {
            ptApp.activate(options: .activateIgnoringOtherApps)
        }
    }

    // MARK: - Private implementation

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

        // ── Send — fire and forget (kAENoReply: returns immediately, PT queues internally) ──
        AppLog.shared.log("[AESpot] Sending Sd2a/SRgn → PT  Trak=-99 TkOf=\(trackOffset) SMSt=\(sampleOffset) Star=\(srcStart) Stop=\(srcStop)")
        var reply = AEDesc()
        let err = AESend(ae.aeDesc,
                         &reply,
                         AESendMode(kAENoReply),
                         AESendPriority(kAENormalPriority),
                         Int32(kAEDefaultTimeout), nil, nil)
        if err != noErr {
            AppLog.shared.log("[AESpot] AESend FAILED OSErr=\(err)")
            throw PTSLError.commandFailed("AESend returned OSErr \(err)")
        }
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
