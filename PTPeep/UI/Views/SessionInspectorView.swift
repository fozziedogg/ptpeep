import AppKit
import SwiftUI

// MARK: - Root inspector view
// Displayed both in the Quick Look extension and the standalone app window.

struct SessionInspectorView: View {
    let session: PTXSession
    let sessionURL: URL
    var onOpenInProTools: (() -> Void)? = nil
    var onClose:         (() -> Void)? = nil

    @State private var showHiddenTracks:   Bool = false
    @State private var showInactiveTracks: Bool = false
    @State private var showVideoTrack:     Bool = true
    @State private var vZoomIdx:           Int  = 2   // 0…4 → vZoomLevels

    private static let vZoomLevels: [CGFloat] = [0.5, 0.75, 1.0, 1.5, 2.5]
    private var verticalScale: CGFloat { Self.vZoomLevels[vZoomIdx] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sessionSetupSection
                    overviewSection
                    tracksSection
                    audioFilesSection
                    pluginsSection
                    memoryLocationsSection
                }
                .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.sessionName)
                    .font(.headline)
                Text(sessionURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let open = onOpenInProTools {
                Button(action: open) {
                    Label("Open in Pro Tools", systemImage: "arrow.up.forward.app")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let close = onClose {
                Button(action: close) {
                    Image(systemName: "xmark.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close session")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Session Setup

    private var sessionSetupSection: some View {
        InspectorSection(title: "Session Setup", systemImage: "info.circle") {
            let rows: [(String, String)] = [
                ("Sample Rate",   session.sampleRate.isEmpty    ? "—" : "\(session.sampleRate) Hz"),
                ("Bit Depth",     session.bitDepth.isEmpty      ? "—" : "\(session.bitDepth)-bit"),
                ("Timecode",      session.tcFormat.isEmpty      ? "—" : session.tcFormat),
                ("Start",         session.sessionStart.isEmpty  ? "—" : session.sessionStart),
                ("Duration",      session.sessionLength.isEmpty ? "—" : session.sessionLength),
                ("Tracks",        "\(session.tracks.count)"),
                ("Audio Files",   "\(session.audioFileNames.count)"),
            ]
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 3) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(spacing: 3) {
                        Text(label + ":")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.caption.monospacedDigit())
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
        }
    }

    // MARK: - Overview (Universe-style timeline)

    private var overviewSection: some View {
        // Only tracks that actually have clips matter for the overview.
        // Toggles are shown only when there are hidden/inactive/video tracks
        // with clips — a toggle that reveals nothing would be confusing.
        let hasHidden   = session.tracks.contains { $0.isHidden   && !$0.clips.isEmpty }
        let hasInactive = session.tracks.contains { $0.isInactive && !$0.clips.isEmpty }
        let hasVideo    = session.tracks.contains { $0.type == .video && !$0.clips.isEmpty }
        let clippedTracks = session.tracks
            .filter {
                !$0.clips.isEmpty
                // Either toggle can reveal a track that is both hidden and inactive.
                && (showHiddenTracks   || !$0.isHidden   || (showInactiveTracks && $0.isInactive))
                && (showInactiveTracks || !$0.isInactive || (showHiddenTracks   && $0.isHidden))
                && (showVideoTrack     || $0.type != .video)
            }
            .sorted { a, b in
                func rank(_ t: PTXTrack) -> Int {
                    if t.type == .video            { return 0 }
                    if t.isInactive && !t.isHidden { return 1 }
                    if t.isHidden                  { return 2 }
                    return 3
                }
                return rank(a) < rank(b)
            }
        let sr = Double(session.sampleRate) ?? 48000.0
        let hasClips = !clippedTracks.isEmpty
        return InspectorSection(title: "Overview", systemImage: "chart.bar.xaxis") {
            if hasClips || hasHidden || hasInactive || hasVideo {
                HStack(spacing: 12) {
                    if hasHidden {
                        Toggle(isOn: $showHiddenTracks) {
                            Text("Show hidden")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if hasInactive {
                        Toggle(isOn: $showInactiveTracks) {
                            Text("Show inactive")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if hasVideo {
                        Toggle(isOn: $showVideoTrack) {
                            Text("Show video")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Spacer()
                    if hasClips {
                        // Vertical zoom: 5 discrete levels like Pro Tools
                        HStack(spacing: 4) {
                            Text("V:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(action: { vZoomIdx = max(0, vZoomIdx - 1) }) {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            Text("\(vZoomIdx + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .center)
                            Button(action: { vZoomIdx = min(4, vZoomIdx + 1) }) {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            if clippedTracks.isEmpty {
                PlaceholderRow(text: "No clip position data — binary block decoder pending")
            } else {
                let videoCount = clippedTracks.filter { $0.type == .video }.count
                let otherCount = min(clippedTracks.count - videoCount, 32)
                let timelineH  = CGFloat(videoCount) * (16 * verticalScale + 2)
                             + CGFloat(otherCount)  * (8  * verticalScale + 2)
                             + 46
                SessionTimelineView(tracks: clippedTracks, sampleRate: sr,
                                    frameRate: session.frameRate, verticalScale: verticalScale)
                    .frame(height: timelineH)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Tracks

    private var tracksSection: some View {
        InspectorSection(title: "Tracks", systemImage: "slider.horizontal.3",
                         count: session.tracks.count, initiallyExpanded: false) {
            if session.tracks.isEmpty {
                PlaceholderRow(text: "No tracks found")
            } else {
                ForEach(session.tracks, id: \.index) { track in
                    TrackRow(track: track)
                }
            }
        }
    }

    // MARK: - Audio Files

    private var audioFilesSection: some View {
        InspectorSection(title: "Audio Files", systemImage: "waveform",
                         count: session.audioFileNames.count, initiallyExpanded: false) {
            if session.audioFileNames.isEmpty {
                PlaceholderRow(text: "No audio files found")
            } else {
                ForEach(Array(session.audioFileNames.enumerated()), id: \.offset) { _, name in
                    AudioFileRow(name: name,
                                 resolved: session.resolvedAudioFiles.first { $0.name == name })
                }
            }
        }
    }

    // MARK: - Plugins

    private var pluginsSection: some View {
        InspectorSection(title: "Plug-Ins Used", systemImage: "puzzlepiece.extension",
                         count: session.plugins.count) {
            if session.plugins.isEmpty {
                PlaceholderRow(text: session.sampleRate.isEmpty
                    ? "Connect to Pro Tools for plug-in list"
                    : "No plug-ins found")
            } else {
                ForEach(session.plugins, id: \.self) { plugin in
                    ListRow(text: plugin, systemImage: "puzzlepiece")
                }
            }
        }
    }

    // MARK: - Memory Locations

    private var memoryLocationsSection: some View {
        InspectorSection(title: "Memory Locations", systemImage: "mappin.and.ellipse",
                         count: session.memoryLocations.count) {
            if session.memoryLocations.isEmpty {
                PlaceholderRow(text: "No memory locations")
            } else {
                ForEach(session.memoryLocations, id: \.number) { loc in
                    HStack(spacing: 8) {
                        Text("\(loc.number)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(loc.name)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Section container

private struct InspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    var count: Int? = nil
    var initiallyExpanded: Bool = true
    @ViewBuilder let content: Content

    @State private var isExpanded: Bool
    init(title: String, systemImage: String, count: Int? = nil,
         initiallyExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.initiallyExpanded = initiallyExpanded
        self.content = content()
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let n = count {
                        Text("(\(n))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .separatorColor).opacity(0.1))

            if isExpanded {
                content
                    .padding(.bottom, 4)
            }

            Divider().padding(.horizontal, 16)
        }
    }
}

// MARK: - Row types

private struct MetadataRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.subheadline.monospacedDigit())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}

private struct TrackRow: View {
    let track: PTXTrack
    var body: some View {
        let dimmed = track.isHidden || track.isInactive
        HStack(spacing: 8) {
            Image(systemName: track.type.systemImage)
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : track.type.tintColor)
                .frame(width: 16)
            Text(track.name)
                .font(.subheadline)
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .italic(track.isInactive)
            HStack(spacing: 4) {
                if track.isHidden {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if track.isInactive {
                    Text("inactive")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(track.type.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}

private struct AudioFileRow: View {
    let name: String
    let resolved: ResolvedAudioFile?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: resolved != nil ? "checkmark.circle" : "circle.dashed")
                .foregroundStyle(resolved != nil ? .green : .secondary)
                .frame(width: 16)
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let url = resolved?.url {
                Text(url.pathExtension.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}

private struct ListRow: View {
    let text: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}

private struct PlaceholderRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

// MARK: - Timeline controller
// Owns zoom state, selection/cursor state, and keyboard navigation.

private final class TimelineController: ObservableObject, @unchecked Sendable {
    // Zoom
    @Published var scale:     Double = 1.0
    @Published var viewStart: Double = 0.0

    // Selection / cursor (absolute timeline fractions 0…1)
    @Published var selStart: Double? = nil   // cursor or selection start
    @Published var selEnd:   Double? = nil   // nil = cursor only
    @Published var selTrack: Int?    = nil   // selected track index

    // Interaction context (not published — used by key handler only)
    var isHovering:   Bool    = false
    var isFocused:    Bool    = false
    var hoverAbsFrac: Double? = nil

    // Navigation context — set by view on appear
    var tracks:       [PTXTrack] = []
    var totalSamples: Double     = 1.0

    private var monitor: Any?

    var window: Double { 1.0 / scale }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isHovering || self.isFocused else { return event }
            guard let ch = event.charactersIgnoringModifiers else { return event }
            let mods   = event.modifierFlags
            let anchor = self.hoverAbsFrac
            switch ch {
            case "t":      self.zoomIn(anchor: anchor);  return nil
            case "r":      self.zoomOut(anchor: anchor); return nil
            case "e", "E": self.zoomToSelection();       return nil
            case "\u{1b}": self.clearSelection();        return nil  // Escape
            case "\t":
                if mods.contains(.option) { self.nextClipEnd()   }
                else if mods.contains(.shift) { self.prevClipStart() }
                else                          { self.nextClipStart() }
                return nil
            default: return event
            }
        }
    }

    func stopMonitoring() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    // MARK: Zoom

    func zoomIn(anchor: Double? = nil) {
        let a      = anchor ?? (viewStart + window / 2)
        let newSc  = min(scale * 1.5, 512)
        let newWin = 1.0 / newSc
        viewStart  = (a - newWin / 2).clamped(to: 0...(1 - newWin))
        scale      = newSc
    }

    func zoomOut(anchor: Double? = nil) {
        let newSc = max(scale / 1.5, 1.0)
        guard newSc > 1.0 else { viewStart = 0; scale = 1.0; return }
        let a      = anchor ?? (viewStart + window / 2)
        let newWin = 1.0 / newSc
        viewStart  = (a - newWin / 2).clamped(to: 0...(1 - newWin))
        scale      = newSc
    }

    func zoomToSelection() {
        guard let s = selStart, let e = selEnd, e > s else {
            scale = 1.0; viewStart = 0.0; return
        }
        let span   = e - s
        let margin = span * 0.1
        let start  = max(0.0, s - margin)
        let end    = min(1.0, e + margin)
        let newWin = end - start
        scale      = max(1.0, 1.0 / newWin)
        viewStart  = start.clamped(to: 0...(1 - window))
    }

    // MARK: Selection

    func clearSelection() {
        selStart = nil; selEnd = nil; selTrack = nil
    }

    // MARK: Clip navigation

    func nextClipStart() {
        guard let idx = selTrack, idx < tracks.count else { return }
        let cursor = selStart ?? 0
        let starts = tracks[idx].clips
            .map { Double($0.startSample) / totalSamples }
            .filter { $0 > cursor + 1e-9 }
            .sorted()
        guard let next = starts.first else { return }
        selStart = next; selEnd = nil
        ensureVisible(next)
    }

    func prevClipStart() {
        guard let idx = selTrack, idx < tracks.count else { return }
        let cursor = selStart ?? 0
        let starts = tracks[idx].clips
            .map { Double($0.startSample) / totalSamples }
            .filter { $0 < cursor - 1e-9 }
            .sorted()
        guard let prev = starts.last else { return }
        selStart = prev; selEnd = nil
        ensureVisible(prev)
    }

    func nextClipEnd() {
        guard let idx = selTrack, idx < tracks.count else { return }
        let cursor = selStart ?? 0
        let ends: [Double] = tracks[idx].clips
            .map { clip -> Double in Double(clip.startSample + clip.lengthSamples) / totalSamples }
            .filter { $0 > cursor + 1e-9 }
            .sorted()
        guard let next = ends.first else { return }
        selStart = next; selEnd = nil
        ensureVisible(next)
    }

    func jumpTo(_ frac: Double) {
        selStart = frac; selEnd = nil
        ensureVisible(frac)
    }

    func ensureVisible(_ frac: Double) {
        let margin = window * 0.1
        if frac < viewStart + margin {
            viewStart = max(0, frac - margin)
        } else if frac > viewStart + window - margin {
            viewStart = min(1 - window, frac - window + margin)
        }
    }
}

// MARK: - Universe-style timeline

private struct SessionTimelineView: View {
    let tracks: [PTXTrack]
    let sampleRate: Double
    var frameRate: Double = 30
    var verticalScale: CGFloat = 1.0

    @StateObject private var tc = TimelineController()

    // Hover state (view-owned for rendering; tc.hoverAbsFrac mirrors it for key handler)
    @State private var hoverAbsFrac: Double? = nil
    @State private var hoverLane:    Int?    = nil

    // Drag/gesture state
    @State private var isDragging:  Bool   = false   // dragging a selection
    @State private var isPanning:   Bool   = false   // option+dragging to pan
    @State private var panOrigin:   (viewStart: Double, window: Double)? = nil

    // TC entry
    @State private var showTCEntry:  Bool   = false
    @State private var tcEntryText:  String = ""

    private static let palette:    [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo, .yellow, .red, .teal, .brown
    ]
    private static let videoColor: Color   = Color(white: 0.52)
    private static let audioLaneH: CGFloat = 8
    private static let videoLaneH: CGFloat = 16
    private static let laneGap:    CGFloat = 2
    private static let rulerH:     CGFloat = 20

    private static func trackLaneH(_ track: PTXTrack) -> CGFloat {
        track.type == .video ? videoLaneH : audioLaneH
    }
    private func scaledLaneH(_ track: PTXTrack) -> CGFloat {
        Self.trackLaneH(track) * verticalScale
    }
    private static func trackColor(_ track: PTXTrack, index: Int) -> Color {
        track.type == .video ? videoColor : palette[index % palette.count]
    }

    /// Returns the track index at a given y position within the canvas lanes.
    private func laneIndex(at y: CGFloat, availH: CGFloat) -> Int? {
        var top: CGFloat = 0
        for (i, track) in tracks.enumerated() {
            let h = scaledLaneH(track)
            if top + h > availH { break }
            if y >= top && y < top + h { return i }
            top += h + Self.laneGap
        }
        return nil
    }

    var body: some View {
        let totalSamples = max(
            tracks.flatMap(\.clips).map { $0.startSample + $0.lengthSamples }.max() ?? 1,
            1
        )
        let sr    = max(sampleRate, 1)
        let total = Double(totalSamples)

        VStack(spacing: 4) {
            // Timeline canvas
            Canvas { ctx, size in
                let availH  = size.height - Self.rulerH
                let vStart  = tc.viewStart
                let vWindow = tc.window

                // Lanes + clips
                var laneY: CGFloat = 0
                for (i, track) in tracks.enumerated() {
                    let thisLaneH = scaledLaneH(track)
                    guard laneY + thisLaneH <= availH else { break }
                    let color      = Self.trackColor(track, index: i)
                    let isSelected = i == tc.selTrack
                    let bgAlpha: Double = isSelected ? 0.22
                        : (track.type == .video ? 0.15 : 0.10)

                    ctx.fill(
                        Path(CGRect(x: 0, y: laneY, width: size.width, height: thisLaneH)),
                        with: .color(color.opacity(bgAlpha))
                    )

                    for clip in track.clips {
                        guard clip.startSample >= 0, clip.lengthSamples > 0 else { continue }
                        let clipFracStart = Double(clip.startSample)   / total
                        let clipFracLen   = Double(clip.lengthSamples) / total
                        let x = CGFloat((clipFracStart - vStart) / vWindow) * size.width
                        let w = max(1, CGFloat(clipFracLen / vWindow) * size.width)
                        guard x + w > 0, x < size.width else { continue }
                        ctx.fill(
                            Path(CGRect(x: x, y: laneY, width: w, height: thisLaneH)),
                            with: .color(color.opacity(0.82))
                        )
                        if w > 32 {
                            let fontSize: CGFloat = track.type == .video ? 8 : 6
                            ctx.draw(
                                Text(clip.name)
                                    .font(.system(size: fontSize).bold())
                                    .foregroundColor(.white),
                                in: CGRect(x: x + 3,
                                           y: laneY + (thisLaneH - fontSize) / 2 - 1,
                                           width: w - 6, height: fontSize + 2)
                            )
                        }
                    }
                    laneY += thisLaneH + Self.laneGap
                }

                // Selection band or cursor line (drawn on top of clips)
                if let sStart = tc.selStart {
                    let sx = CGFloat((sStart - vStart) / vWindow) * size.width
                    if let sEnd = tc.selEnd {
                        let ex = CGFloat((sEnd - vStart) / vWindow) * size.width
                        let x  = min(sx, ex)
                        let w  = max(1, abs(ex - sx))
                        ctx.fill(
                            Path(CGRect(x: x, y: 0, width: w, height: availH)),
                            with: .color(Color.accentColor.opacity(0.18))
                        )
                        ctx.fill(Path(CGRect(x: x,         y: 0, width: 1, height: availH)),
                                 with: .color(Color.accentColor.opacity(0.7)))
                        ctx.fill(Path(CGRect(x: x + w - 1, y: 0, width: 1, height: availH)),
                                 with: .color(Color.accentColor.opacity(0.7)))
                    } else if sx >= 0, sx <= size.width {
                        ctx.fill(
                            Path(CGRect(x: sx - 0.5, y: 0, width: 1, height: availH)),
                            with: .color(.primary.opacity(0.75))
                        )
                    }
                }

                // Ruler
                let rulerY = size.height - Self.rulerH
                ctx.fill(
                    Path(CGRect(x: 0, y: rulerY, width: size.width, height: 0.5)),
                    with: .color(.secondary.opacity(0.35))
                )
                let steps = 5
                for i in 0...steps {
                    let frac  = Double(i) / Double(steps)
                    let x     = CGFloat(frac) * size.width
                    let secs  = (vStart + frac * vWindow) * total / sr
                    ctx.fill(
                        Path(CGRect(x: x, y: rulerY, width: 0.5, height: 5)),
                        with: .color(.secondary.opacity(0.5))
                    )
                    let anchor: UnitPoint = i == 0 ? .topLeading : (i == steps ? .topTrailing : .top)
                    ctx.draw(
                        Text(Self.formatTC(secs, fps: frameRate))
                            .font(.system(size: 9).monospacedDigit()),
                        at: CGPoint(x: x, y: rulerY + 6),
                        anchor: anchor
                    )
                }

                // Hover hairline (on top of everything)
                if let absFrac = hoverAbsFrac {
                    let hx = CGFloat((absFrac - vStart) / vWindow) * size.width
                    if hx >= 0, hx <= size.width {
                        ctx.fill(
                            Path(CGRect(x: hx, y: 0, width: 0.5, height: availH)),
                            with: .color(.primary.opacity(0.35))
                        )
                    }
                }
            }
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                tc.isHovering   = true
                                let screenFrac  = Double(loc.x / geo.size.width).clamped(to: 0...1)
                                let absFrac     = tc.viewStart + screenFrac * tc.window
                                hoverAbsFrac    = absFrac
                                tc.hoverAbsFrac = absFrac
                                hoverLane = laneIndex(at: loc.y,
                                                      availH: geo.size.height - Self.rulerH)
                            case .ended:
                                tc.isHovering   = false
                                tc.hoverAbsFrac = nil
                                hoverAbsFrac    = nil
                                hoverLane       = nil
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { val in
                                    let dist = hypot(val.translation.width, val.translation.height)
                                    tc.isFocused = true

                                    // Below threshold: still deciding click vs drag
                                    guard dist >= 3 else { return }

                                    let curFrac: Double = (Double(val.location.x / geo.size.width)
                                        * tc.window + tc.viewStart).clamped(to: 0...1)

                                    if NSEvent.modifierFlags.contains(.option) {
                                        // Option+drag → pan
                                        if !isPanning {
                                            isPanning = true
                                            panOrigin = (tc.viewStart, tc.window)
                                        }
                                        if let o = panOrigin {
                                            let delta = -Double(val.translation.width / geo.size.width) * o.window
                                            tc.viewStart = (o.viewStart + delta).clamped(to: 0...(1 - tc.window))
                                        }
                                    } else {
                                        // Drag → time selection
                                        if !isDragging {
                                            isDragging = true
                                            let startFrac = (Double(val.startLocation.x / geo.size.width)
                                                * tc.window + tc.viewStart).clamped(to: 0...1)
                                            tc.selStart = startFrac
                                            tc.selTrack = laneIndex(at: val.startLocation.y,
                                                                     availH: geo.size.height - Self.rulerH)
                                        }
                                        tc.selEnd = curFrac
                                    }
                                }
                                .onEnded { val in
                                    let dist = hypot(val.translation.width, val.translation.height)
                                    if dist < 3 {
                                        // Click → place cursor
                                        let frac = (Double(val.location.x / geo.size.width)
                                            * tc.window + tc.viewStart).clamped(to: 0...1)
                                        tc.selStart = frac
                                        tc.selEnd   = nil
                                        tc.selTrack = laneIndex(at: val.location.y,
                                                                 availH: geo.size.height - Self.rulerH)
                                        tc.isFocused = true
                                    } else if isDragging {
                                        // Normalize selection so start <= end
                                        if let s = tc.selStart, let e = tc.selEnd, e < s {
                                            let tmp = tc.selStart; tc.selStart = tc.selEnd; tc.selEnd = tmp
                                        }
                                    }
                                    isDragging = false
                                    isPanning  = false
                                    panOrigin  = nil
                                }
                        )
                }
            )

            // Info strip
            HStack(spacing: 8) {
                // Position: click to open TC entry; cursor/selection > hover
                Button {
                    tcEntryText = tc.selStart.map { Self.formatTC($0 * total / sr, fps: frameRate) } ?? ""
                    showTCEntry = true
                } label: {
                    Group {
                        if let s = tc.selStart {
                            if let e = tc.selEnd {
                                let lo  = min(s, e)
                                let dur = abs(e - s) * total / sr
                                Text("\(Self.formatTC(lo * total / sr, fps: frameRate))  +\(Self.formatTC(dur, fps: frameRate))")
                                    .foregroundStyle(.primary)
                            } else {
                                Text(Self.formatTC(s * total / sr, fps: frameRate))
                                    .foregroundStyle(.primary)
                            }
                        } else if let absFrac = hoverAbsFrac {
                            Text(Self.formatTC(absFrac * total / sr, fps: frameRate))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("──:──:──:──")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Click to go to timecode")
                .popover(isPresented: $showTCEntry, arrowEdge: .top) {
                    TCEntryPopover(text: $tcEntryText) { text in
                        if let frac = Self.parseTCFrac(text, fps: frameRate,
                                                       total: total, sr: sr) {
                            tc.jumpTo(frac)
                        }
                        showTCEntry = false
                    }
                }

                Divider().frame(height: 10)

                // Track: selected track takes priority over hovered
                Group {
                    let displayIdx = tc.selTrack ?? hoverLane
                    if let idx = displayIdx, idx < tracks.count {
                        let track = tracks[idx]
                        let color = Self.trackColor(track, index: idx)
                        Text(track.name).foregroundStyle(color)
                        Text("[\(track.channelFormat)]").foregroundStyle(.secondary)
                        // Clip name under cursor (hover only, not shown for selection)
                        if tc.selTrack == nil, let absFrac = hoverAbsFrac {
                            let hovSample = Int64(absFrac * total)
                            if let clip = track.clips.first(where: {
                                hovSample >= $0.startSample
                                    && hovSample < $0.startSample + $0.lengthSamples
                            }) {
                                Text("· \(clip.name)").foregroundStyle(color)
                            }
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Horizontal zoom controls
                HStack(spacing: 4) {
                    Text("H:")
                        .foregroundStyle(.secondary)
                    Button { tc.zoomOut(anchor: hoverAbsFrac) } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    Text(tc.scale > 1.01 ? "×\(String(format: "%.1f", tc.scale))" : "Fit")
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .center)
                    Button { tc.zoomIn(anchor: hoverAbsFrac) } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 2)
            .frame(height: 14)
        }
        .onAppear {
            tc.tracks       = tracks
            tc.totalSamples = total
            tc.startMonitoring()
        }
        .onDisappear { tc.stopMonitoring() }
    }

    private static func formatTC(_ seconds: Double, fps: Double) -> String {
        guard seconds.isFinite, seconds >= 0, fps > 0 else { return "0:00:00:00" }
        let totalFrames = Int(seconds * fps)
        let fr  = Int(fps)
        let f   = totalFrames % fr
        let sec = (totalFrames / fr) % 60
        let min = (totalFrames / fr / 60) % 60
        let hr  = totalFrames / fr / 3600
        return String(format: "%d:%02d:%02d:%02d", hr, min, sec, f)
    }

    /// Parses a timecode string (H:MM:SS:FF or subsets, or plain seconds) into
    /// an absolute timeline fraction. Returns nil if unparseable.
    static func parseTCFrac(_ text: String, fps: Double, total: Double, sr: Double) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Plain seconds
        if let secs = Double(s) {
            return (secs * sr / total).clamped(to: 0...1)
        }
        // H:MM:SS:FF or subsets
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        var h = 0, m = 0, sec = 0, f = 0
        switch parts.count {
        case 1:  sec = parts[0]
        case 2:  m = parts[0]; sec = parts[1]
        case 3:  h = parts[0]; m = parts[1]; sec = parts[2]
        default: h = parts[0]; m = parts[1]; sec = parts[2]; f = parts[3]
        }
        let totalSecs = Double(h * 3600 + m * 60 + sec) + Double(f) / max(fps, 1)
        return (totalSecs * sr / total).clamped(to: 0...1)
    }
}

// MARK: - TC entry popover

private struct TCEntryPopover: View {
    @Binding var text: String
    let onCommit: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("0:00:00:00", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 90)
                .focused($focused)
                .onSubmit { onCommit(text) }
            Button("Go") { onCommit(text) }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { focused = true }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - PTXTrackType convenience

private extension PTXTrackType {
    var systemImage: String {
        switch self {
        case .audio:      return "waveform"
        case .midi:       return "pianokeys"
        case .aux:        return "arrow.triangle.branch"
        case .master:     return "slider.vertical.3"
        case .vca:        return "dial.high"
        case .video:      return "film"
        case .folder:     return "folder"
        case .instrument: return "pianokeys.inverse"
        case .unknown:    return "questionmark.circle"
        }
    }

    var tintColor: AnyShapeStyle {
        switch self {
        case .video:  return AnyShapeStyle(.purple)
        case .folder: return AnyShapeStyle(.brown)
        case .vca:    return AnyShapeStyle(.orange)
        case .aux:    return AnyShapeStyle(.teal)
        default:      return AnyShapeStyle(.secondary)
        }
    }
}
