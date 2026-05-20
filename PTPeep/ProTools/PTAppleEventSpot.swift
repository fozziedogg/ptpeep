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
                    let fileLen = PTSLSessionInfo.aeFileLength(url: url,
                                                               fallback: clip.sourceOffset + clip.lengthSamples)
                    let offset  = Int32(clamping: clip.startSample - regStart)
                    AppLog.shared.log("[AESpot] clip='\(clip.name)' track+\(segIdx) SMSt=\(offset) fileLen=\(fileLen) url=\(url.lastPathComponent)")
                    try PTSLSessionInfo.aeSendSpot(
                        url:          url,
                        srcStart:     0,                       // full pre-roll handle
                        srcStop:      Int32(clamping: fileLen), // full post-roll handle
                        name:         clip.name,
                        trackOffset:  Int16(segIdx),
                        sampleOffset: offset,
                        stream:       1
                    )
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
                         AESendMode(kAENoReply | kAECanInteract),
                         AESendPriority(kAENormalPriority),
                         Int32(kAEDefaultTimeout), nil, nil)
        AEDisposeDesc(&reply)
        if err == noErr {
            AppLog.shared.log("[AESpot] AESend OK")
        } else {
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
