import Foundation

// MARK: - Pure timeline navigation helpers
//
// No SwiftUI dependency — compile alongside PTXSession.swift for unit tests:
//   swiftc PTPeep/Parser/PTXSession.swift PTPeep/UI/TimelineNav.swift \
//          Tests/test_timeline_nav.swift -o /tmp/test_nav && /tmp/test_nav

enum TimelineNav {

    // MARK: Clip navigation

    /// Absolute fraction of the next clip start after `cursor` on `trackIdx`.
    static func nextClipStart(tracks: [PTXTrack], total: Double,
                               trackIdx: Int, cursor: Double,
                               hideMuted: Bool = false) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        return tracks[trackIdx].clips
            .filter { !hideMuted || !$0.isMuted }
            .map { Double($0.startSample) / total }
            .filter { $0 > cursor + 1e-9 }
            .min()
    }

    /// Absolute fraction of the previous clip start before `cursor` on `trackIdx`.
    static func prevClipStart(tracks: [PTXTrack], total: Double,
                               trackIdx: Int, cursor: Double,
                               hideMuted: Bool = false) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        return tracks[trackIdx].clips
            .filter { !hideMuted || !$0.isMuted }
            .map { Double($0.startSample) / total }
            .filter { $0 < cursor - 1e-9 }
            .max()
    }

    /// Absolute fraction of the next clip end after `cursor` on `trackIdx`.
    static func nextClipEnd(tracks: [PTXTrack], total: Double,
                             trackIdx: Int, cursor: Double,
                             hideMuted: Bool = false) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        let ends: [Double] = tracks[trackIdx].clips
            .filter { !hideMuted || !$0.isMuted }
            .map { Double($0.startSample + $0.lengthSamples) / total }
        return ends.filter { $0 > cursor + 1e-9 }.min()
    }

    /// Next clip boundary (start or end) after `cursor` — Tab behaviour.
    static func nextBoundary(tracks: [PTXTrack], total: Double,
                              trackIdx: Int, cursor: Double,
                              hideMuted: Bool = false) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        var boundaries: [Double] = []
        for clip in tracks[trackIdx].clips where !hideMuted || !clip.isMuted {
            boundaries.append(Double(clip.startSample) / total)
            boundaries.append(Double(clip.startSample + clip.lengthSamples) / total)
        }
        return boundaries.filter { $0 > cursor + 1e-9 }.min()
    }

    /// Previous clip boundary (start or end) before `cursor` — Shift+Tab behaviour.
    static func prevBoundary(tracks: [PTXTrack], total: Double,
                              trackIdx: Int, cursor: Double,
                              hideMuted: Bool = false) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        var boundaries: [Double] = []
        for clip in tracks[trackIdx].clips where !hideMuted || !clip.isMuted {
            boundaries.append(Double(clip.startSample) / total)
            boundaries.append(Double(clip.startSample + clip.lengthSamples) / total)
        }
        return boundaries.filter { $0 < cursor - 1e-9 }.max()
    }

    // MARK: TC parsing

    /// Parses a timecode string into an absolute timeline fraction (0…1).
    ///
    /// Accepts: H:MM:SS:FF, H:MM:SS, M:SS, plain seconds.
    /// Returns nil if unparseable or out of range.
    static func parseTCFrac(_ text: String, fps: Double,
                             totalSamples: Double, sampleRate: Double) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, totalSamples > 0, sampleRate > 0 else { return nil }

        // Converts TC components → sample position using nominal frame count.
        // For pulldown rates (23.976, 29.97) fps is exact rational (e.g. 24000/1001),
        // so sampleRate/fps = exact samples-per-nominal-frame (e.g. 2002 at 48kHz).
        let nomFPS = fps.rounded()  // 24 for 23.976fps, 30 for 29.97fps, etc.
        func tcToFrac(h: Int, m: Int, sec: Int, f: Int) -> Double {
            let frames = Double(h) * 3600 * nomFPS + Double(m) * 60 * nomFPS + Double(sec) * nomFPS + Double(f)
            return clamp(frames * sampleRate / fps / totalSamples)
        }

        // All-digit string with 4+ digits: right-align into HHMMSSFF
        // e.g. "01123714" → 01:12:37:14,  "123714" → 00:12:37:14
        if s.count >= 4, s.allSatisfy({ $0.isNumber }) {
            let src     = String(s.suffix(8))
            let padded  = String(repeating: "0", count: max(0, 8 - src.count)) + src
            let h   = Int(padded.prefix(2)) ?? 0
            let m   = Int(padded.dropFirst(2).prefix(2)) ?? 0
            let sec = Int(padded.dropFirst(4).prefix(2)) ?? 0
            let f   = Int(padded.dropFirst(6).prefix(2)) ?? 0
            return tcToFrac(h: h, m: m, sec: sec, f: f)
        }

        // Plain seconds (1–3 digit strings or decimal)
        if let secs = Double(s) {
            return clamp(secs * sampleRate / totalSamples)
        }

        // Colon-separated components
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }

        var h = 0, m = 0, sec = 0, f = 0
        switch parts.count {
        case 1:       sec = parts[0]
        case 2:  m = parts[0]; sec = parts[1]
        case 3:  h = parts[0];  m = parts[1]; sec = parts[2]
        default: h = parts[0];  m = parts[1]; sec = parts[2]; f = parts[3]
        }
        return tcToFrac(h: h, m: m, sec: sec, f: f)
    }

    // MARK: Private

    private static func clamp(_ v: Double) -> Double {
        Swift.max(0.0, Swift.min(1.0, v))
    }
}
