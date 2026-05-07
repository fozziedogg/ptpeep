// Timeline navigation unit tests
// Compile and run:
//   swiftc PTPeep/Parser/PTXSession.swift PTPeep/UI/TimelineNav.swift \
//          Tests/test_timeline_nav.swift -o /tmp/test_nav && /tmp/test_nav

import Foundation

@main
struct TestTimelineNav {
    static func main() {
        var failures = 0

        func check(_ condition: Bool, _ message: String, line: Int = #line) {
            if condition {
                print("  ✓  \(message)")
            } else {
                print("  ✗  FAIL [\(line)]: \(message)")
                failures += 1
            }
        }

        // MARK: - Fixtures
        // Track with clips at 0–100, 200–100, 500–200 (session = 1000 samples)
        //   clip 0: frac 0.000 → 0.100
        //   clip 1: frac 0.200 → 0.300
        //   clip 2: frac 0.500 → 0.700
        let total: Double = 1000
        var t = PTXTrack(index: 0, name: "A")
        t.clips = [
            PTXClip(name: "c0", startSample:   0, lengthSamples: 100),
            PTXClip(name: "c1", startSample: 200, lengthSamples: 100),
            PTXClip(name: "c2", startSample: 500, lengthSamples: 200),
        ]
        let tracks = [t]

        // MARK: - nextClipStart
        print("\nnextClipStart:")
        check(TimelineNav.nextClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: -0.01) == 0.0,
              "before first clip → 0.0")
        check(TimelineNav.nextClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.0) == 0.2,
              "at clip 0 start → 0.2 (skip self, go to next)")
        check(TimelineNav.nextClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.05) == 0.2,
              "inside clip 0 → 0.2")
        check(TimelineNav.nextClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.2) == 0.5,
              "at clip 1 start → 0.5 (skip self)")
        check(TimelineNav.nextClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.5) == nil,
              "at last clip start → nil")
        check(TimelineNav.nextClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.99) == nil,
              "after last clip → nil")
        check(TimelineNav.nextClipStart(tracks: tracks, total: total, trackIdx: 1, cursor: 0.0) == nil,
              "out-of-range track → nil")

        // MARK: - prevClipStart
        print("\nprevClipStart:")
        check(TimelineNav.prevClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.0) == nil,
              "at clip 0 start → nil")
        check(TimelineNav.prevClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.1) == 0.0,
              "inside clip 0 → 0.0")
        check(TimelineNav.prevClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.2) == 0.0,
              "at clip 1 start → 0.0 (skip self)")
        check(TimelineNav.prevClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.5) == 0.2,
              "at clip 2 start → 0.2 (skip self)")
        check(TimelineNav.prevClipStart(tracks: tracks, total: total, trackIdx: 0, cursor: 0.99) == 0.5,
              "after last clip → 0.5")

        // MARK: - nextClipEnd
        print("\nnextClipEnd:")
        check(TimelineNav.nextClipEnd(tracks: tracks, total: total, trackIdx: 0, cursor: 0.0) == 0.1,
              "at session start → 0.1")
        check(TimelineNav.nextClipEnd(tracks: tracks, total: total, trackIdx: 0, cursor: 0.1) == 0.3,
              "at clip 0 end → 0.3 (skip self)")
        check(TimelineNav.nextClipEnd(tracks: tracks, total: total, trackIdx: 0, cursor: 0.3) == 0.7,
              "at clip 1 end → 0.7 (skip self)")
        check(TimelineNav.nextClipEnd(tracks: tracks, total: total, trackIdx: 0, cursor: 0.7) == nil,
              "at last clip end → nil")

        // MARK: - nextBoundary / prevBoundary (Tab / Shift+Tab)
        // boundaries in order: 0.0, 0.1, 0.2, 0.3, 0.5, 0.7
        print("\nnextBoundary (Tab):")
        check(TimelineNav.nextBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: -0.01) == 0.0,
              "before session → 0.0 (clip 0 start)")
        check(TimelineNav.nextBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.0) == 0.1,
              "at clip 0 start → 0.1 (clip 0 end)")
        check(TimelineNav.nextBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.05) == 0.1,
              "inside clip 0 → 0.1 (clip 0 end)")
        check(TimelineNav.nextBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.1) == 0.2,
              "at clip 0 end → 0.2 (clip 1 start)")
        check(TimelineNav.nextBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.25) == 0.3,
              "inside gap after clip 1 → 0.3 (clip 1 end)")
        check(TimelineNav.nextBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.7) == nil,
              "after last boundary → nil")

        print("\nprevBoundary (Shift+Tab):")
        check(TimelineNav.prevBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.0) == nil,
              "at first boundary → nil")
        check(TimelineNav.prevBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.05) == 0.0,
              "inside clip 0 → 0.0 (clip 0 start)")
        check(TimelineNav.prevBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.1) == 0.0,
              "at clip 0 end → 0.0 (skip self)")
        check(TimelineNav.prevBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.2) == 0.1,
              "at clip 1 start → 0.1 (clip 0 end)")
        check(TimelineNav.prevBoundary(tracks: tracks, total: total, trackIdx: 0, cursor: 0.99) == 0.7,
              "after last clip → 0.7 (clip 2 end)")

        // MARK: - parseTCFrac
        // 1-hour session at 48kHz / 30fps = 172,800,000 samples
        let sr:  Double = 48000
        let fps: Double = 30
        let dur: Double = 3600 * sr

        func parseCheck(_ text: String, expected: Double?, tol: Double = 1e-6, line: Int = #line) {
            let result = TimelineNav.parseTCFrac(text, fps: fps, totalSamples: dur, sampleRate: sr)
            if let e = expected {
                if let r = result {
                    check(abs(r - e) < tol,
                          "'\(text)' → \(String(format: "%.7f", r)) (want ~\(String(format: "%.7f", e)))",
                          line: line)
                } else {
                    check(false, "'\(text)' → nil, expected \(e)", line: line)
                }
            } else {
                check(result == nil, "'\(text)' should be nil, got \(result.map{"\($0)"} ?? "nil")", line: line)
            }
        }

        print("\nparseTCFrac (1-hr session @ 48kHz/30fps):")
        parseCheck("0:00:00:00", expected: 0.0)
        parseCheck("0:30:00:00", expected: 0.5)          // 30 min = halfway
        parseCheck("1:00:00:00", expected: 1.0)          // exactly 1 hour → 1.0
        parseCheck("2:00:00:00", expected: 1.0)          // past end → clamps to 1.0
        parseCheck("0:00:30:00", expected: 30.0 / 3600)  // 30 seconds
        parseCheck("0:01:00",    expected: 60.0 / 3600)  // 3-component: 1 minute
        parseCheck("60",         expected: 60.0 / 3600)  // plain seconds
        parseCheck("1800",       expected: 0.5)           // 1800 s = 30 min
        parseCheck("0:00:00:15", expected: 0.5 / 3600,   // 15 frames = 0.5 sec
                   tol: 1e-5)
        parseCheck("",           expected: nil)
        parseCheck("abc",        expected: nil)

        // MARK: - Results
        print("\n─────────────────────────────")
        if failures == 0 {
            print("All \(failures == 0 ? "tests" : "\(failures)") passed ✓")
        } else {
            print("\(failures) test(s) FAILED ✗")
            exit(1)
        }
    }
}
