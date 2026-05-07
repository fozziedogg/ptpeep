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
                               trackIdx: Int, cursor: Double) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        return tracks[trackIdx].clips
            .map { Double($0.startSample) / total }
            .filter { $0 > cursor + 1e-9 }
            .min()
    }

    /// Absolute fraction of the previous clip start before `cursor` on `trackIdx`.
    static func prevClipStart(tracks: [PTXTrack], total: Double,
                               trackIdx: Int, cursor: Double) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        return tracks[trackIdx].clips
            .map { Double($0.startSample) / total }
            .filter { $0 < cursor - 1e-9 }
            .max()
    }

    /// Absolute fraction of the next clip end after `cursor` on `trackIdx`.
    static func nextClipEnd(tracks: [PTXTrack], total: Double,
                             trackIdx: Int, cursor: Double) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        let ends: [Double] = tracks[trackIdx].clips.map { clip -> Double in
            Double(clip.startSample + clip.lengthSamples) / total
        }
        return ends.filter { $0 > cursor + 1e-9 }.min()
    }

    /// Next clip boundary (start or end) after `cursor` — Tab behaviour.
    static func nextBoundary(tracks: [PTXTrack], total: Double,
                              trackIdx: Int, cursor: Double) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        let clips = tracks[trackIdx].clips
        var boundaries: [Double] = []
        for clip in clips {
            boundaries.append(Double(clip.startSample) / total)
            boundaries.append(Double(clip.startSample + clip.lengthSamples) / total)
        }
        return boundaries.filter { $0 > cursor + 1e-9 }.min()
    }

    /// Previous clip boundary (start or end) before `cursor` — Shift+Tab behaviour.
    static func prevBoundary(tracks: [PTXTrack], total: Double,
                              trackIdx: Int, cursor: Double) -> Double? {
        guard trackIdx < tracks.count else { return nil }
        let clips = tracks[trackIdx].clips
        var boundaries: [Double] = []
        for clip in clips {
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

        // Plain seconds
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
        let totalSecs = Double(h * 3600 + m * 60 + sec) + Double(f) / max(fps, 1)
        return clamp(totalSecs * sampleRate / totalSamples)
    }

    // MARK: Private

    private static func clamp(_ v: Double) -> Double {
        Swift.max(0.0, Swift.min(1.0, v))
    }
}
