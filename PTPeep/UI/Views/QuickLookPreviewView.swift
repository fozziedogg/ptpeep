import SwiftUI

// MARK: - Quick Look preview for .ptx sessions
//
// Design:
//   • Header: session name · sample rate · bit depth · TC format
//   • Timeline ruler: ← TC (start)    TC (end) →  (arrows point outward)
//   • Track rows concentrated to earliest–latest clip range
//   • Empty tracks visible; hidden/inactive tracks suppressed
//   • Plugins: ✓/✗ when cache is valid; plain list + note when stale/missing

struct QuickLookPreviewView: View {
    let session:      PTXSession
    let pluginResult: PluginScanner.QLResult

    private static let rowH:   CGFloat = 15
    private static let rulerH: CGFloat = 26

    private var visibleTracks: [PTXTrack] {
        session.tracks.filter { !$0.isHidden && !$0.isInactive }
    }

    private var sr:  Double { Double(session.sampleRate) ?? 48000 }
    private var fps: Double { session.frameRate }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            timelineSection
            if !session.plugins.isEmpty {
                Divider()
                pluginsSection
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 0) {
            Text(session.sessionName.isEmpty ? "Pro Tools Session" : session.sessionName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            let meta = [
                session.sampleRate.isEmpty ? nil : "\(session.sampleRate) Hz",
                session.bitDepth.isEmpty   ? nil : "\(session.bitDepth)-bit",
                session.tcFormat.isEmpty   ? nil : session.tcFormat,
            ].compactMap { $0 }
            if !meta.isEmpty {
                Text("  ·  \(meta.joined(separator: "  ·  "))")
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineSection: some View {
        let tracks = visibleTracks
        if tracks.isEmpty {
            Text("No tracks")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal)
        } else {
            let (start, end) = clipRange(tracks)
            VStack(spacing: 0) {
                ruler(start: start, end: end)
                ScrollView(.vertical, showsIndicators: false) {
                    Canvas { ctx, size in
                        drawTracks(ctx: ctx, size: size,
                                   tracks: tracks, rangeStart: start, rangeEnd: end)
                    }
                    .frame(height: CGFloat(tracks.count) * Self.rowH + 2)
                }
                .frame(maxHeight: min(CGFloat(tracks.count) * Self.rowH + 2, 340))
            }
        }
    }

    private func ruler(start: Int64, end: Int64) -> some View {
        let hasClips = start < end
        let startTC  = hasClips ? formatTC(samples: start, sr: sr, fps: fps) : "—"
        let endTC    = hasClips ? formatTC(samples: end,   sr: sr, fps: fps) : "—"
        return HStack {
            Text("← \(startTC)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(endTC) →")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func drawTracks(ctx: GraphicsContext, size: CGSize,
                            tracks: [PTXTrack], rangeStart: Int64, rangeEnd: Int64) {
        let range = Double(max(1, rangeEnd - rangeStart))
        let rH    = Self.rowH

        for (i, track) in tracks.enumerated() {
            let y     = CGFloat(i) * rH + 1
            let color = ptTrackColor(track, index: i)

            // Track background stripe
            ctx.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: rH - 1)),
                with: .color(color.opacity(0.13))
            )

            // Clip rectangles
            for clip in track.clips where !clip.isMuted {
                let x = CGFloat(Double(clip.startSample - rangeStart) / range) * size.width
                let w = max(2, CGFloat(Double(clip.lengthSamples) / range) * size.width)
                ctx.fill(
                    Path(CGRect(x: x, y: y + 1, width: w, height: rH - 3)),
                    with: .color(color)
                )
            }
        }
    }

    private func clipRange(_ tracks: [PTXTrack]) -> (Int64, Int64) {
        var earliest = Int64.max
        var latest   = Int64.min
        for t in tracks {
            for c in t.clips {
                earliest = min(earliest, c.startSample)
                latest   = max(latest, c.startSample + c.lengthSamples)
            }
        }
        guard earliest != .max else { return (0, 0) }
        return (earliest, latest)
    }

    // MARK: - Plugins

    @ViewBuilder
    private var pluginsSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Plug-Ins (\(session.plugins.count))")
                    .font(.subheadline).bold()
                    .padding(.bottom, 2)

                switch pluginResult {
                case .valid(let index):
                    ForEach(session.plugins, id: \.self) { name in
                        let ok = index.contains(name, secondString: session.pluginSecondStrings[name])
                        HStack(spacing: 6) {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(ok ? .green : .red)
                                .font(.caption)
                            Text(name).font(.caption)
                        }
                    }
                case .stale:
                    pluginNameList
                    Text("Open PTPeep to update plug-in scan")
                        .font(.caption2).foregroundColor(.secondary).italic()
                        .padding(.top, 3)
                case .missing:
                    pluginNameList
                    Text("Open PTPeep to scan plug-ins")
                        .font(.caption2).foregroundColor(.secondary).italic()
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: 220)
    }

    private var pluginNameList: some View {
        ForEach(session.plugins, id: \.self) { name in
            Text(name).font(.caption).foregroundColor(.secondary)
        }
    }
}
