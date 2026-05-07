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
    @State private var verticalScale:      CGFloat = 1.0

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
                        HStack(spacing: 4) {
                            Text("V:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(action: { verticalScale = max(0.5, verticalScale / 1.5) }) {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            Text("\(Int(verticalScale * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .center)
                            Button(action: { verticalScale = min(8, verticalScale * 1.5) }) {
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

// MARK: - Zoom controller

private final class ZoomController: ObservableObject, @unchecked Sendable {
    @Published var scale: Double     = 1.0   // 1 = full fit, higher = zoomed in
    @Published var viewStart: Double = 0.0   // absolute timeline fraction at left edge

    var isHovering:   Bool    = false
    var hoverAbsFrac: Double? = nil          // absolute timeline fraction under cursor

    private var monitor: Any?

    var window: Double { 1.0 / scale }       // fraction of timeline currently visible

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isHovering,
                  let ch = event.charactersIgnoringModifiers else { return event }
            let anchor = self.hoverAbsFrac
            switch ch {
            case "t": self.zoomIn(anchor: anchor);  return nil
            case "r": self.zoomOut(anchor: anchor); return nil
            default:  return event
            }
        }
    }

    func stopMonitoring() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

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

    func pan(by delta: Double) {
        viewStart = (viewStart + delta).clamped(to: 0...(1 - window))
    }
}

// MARK: - Universe-style timeline

private struct SessionTimelineView: View {
    let tracks: [PTXTrack]
    let sampleRate: Double
    var frameRate: Double = 30
    var verticalScale: CGFloat = 1.0

    @StateObject private var zoom = ZoomController()
    @State private var hoverAbsFrac: Double? = nil
    @State private var hoverLane:    Int?    = nil
    @State private var dragOrigin:   (viewStart: Double, window: Double)? = nil

    private static let palette:     [Color]  = [
        .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo, .yellow, .red, .teal, .brown
    ]
    private static let videoColor:  Color    = Color(white: 0.52)
    private static let audioLaneH:  CGFloat  = 8
    private static let videoLaneH:  CGFloat  = 16
    private static let laneGap:     CGFloat  = 2
    private static let rulerH:      CGFloat  = 20

    private static func trackLaneH(_ track: PTXTrack) -> CGFloat {
        track.type == .video ? videoLaneH : audioLaneH
    }
    private func scaledLaneH(_ track: PTXTrack) -> CGFloat {
        Self.trackLaneH(track) * verticalScale
    }
    private static func trackColor(_ track: PTXTrack, index: Int) -> Color {
        track.type == .video ? videoColor : palette[index % palette.count]
    }

    var body: some View {
        let totalSamples = max(
            tracks.flatMap(\.clips).map { $0.startSample + $0.lengthSamples }.max() ?? 1,
            1
        )
        let sr     = max(sampleRate, 1)
        let total  = Double(totalSamples)

        VStack(spacing: 4) {
            // Timeline canvas
            Canvas { ctx, size in
                let availH  = size.height - Self.rulerH
                let vStart  = zoom.viewStart
                let vWindow = zoom.window

                // Lanes + clips (variable height: video=16px, audio=8px)
                var laneY: CGFloat = 0
                for (i, track) in tracks.enumerated() {
                    let thisLaneH = scaledLaneH(track)
                    guard laneY + thisLaneH <= availH else { break }
                    let color = Self.trackColor(track, index: i)

                    ctx.fill(
                        Path(CGRect(x: 0, y: laneY, width: size.width, height: thisLaneH)),
                        with: .color(color.opacity(track.type == .video ? 0.15 : 0.10))
                    )
                    for clip in track.clips {
                        guard clip.startSample >= 0, clip.lengthSamples > 0 else { continue }
                        let clipFracStart = Double(clip.startSample)  / total
                        let clipFracLen   = Double(clip.lengthSamples) / total
                        let x = CGFloat((clipFracStart - vStart) / vWindow) * size.width
                        let w = max(1, CGFloat(clipFracLen / vWindow) * size.width)
                        guard x + w > 0, x < size.width else { continue }
                        ctx.fill(
                            Path(CGRect(x: x, y: laneY, width: w, height: thisLaneH)),
                            with: .color(color.opacity(0.82))
                        )
                        // Clip name label inside clip when wide enough
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
                        Text(Self.formatTC(secs, fps: frameRate)).font(.system(size: 9).monospacedDigit()),
                        at: CGPoint(x: x, y: rulerY + 6),
                        anchor: anchor
                    )
                }

                // Hover hairline
                if let absFrac = hoverAbsFrac {
                    let hx = CGFloat((absFrac - vStart) / vWindow) * size.width
                    if hx >= 0, hx <= size.width {
                        ctx.fill(
                            Path(CGRect(x: hx, y: 0, width: 0.5, height: availH)),
                            with: .color(.primary.opacity(0.45))
                        )
                    }
                }
            }
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                zoom.isHovering = true
                                let screenFrac  = Double(loc.x / geo.size.width).clamped(to: 0...1)
                                let absFrac     = zoom.viewStart + screenFrac * zoom.window
                                hoverAbsFrac    = absFrac
                                zoom.hoverAbsFrac = absFrac
                                // Variable-height lane hit detection
                                var found: Int? = nil
                                var laneTop: CGFloat = 0
                                let availableH = geo.size.height - Self.rulerH
                                for (idx, trk) in tracks.enumerated() {
                                    let h = scaledLaneH(trk)
                                    if laneTop + h > availableH { break }
                                    if loc.y >= laneTop && loc.y < laneTop + h { found = idx; break }
                                    laneTop += h + Self.laneGap
                                }
                                hoverLane = found
                            case .ended:
                                zoom.isHovering   = false
                                zoom.hoverAbsFrac = nil
                                hoverAbsFrac      = nil
                                hoverLane         = nil
                            }
                        }
                        // Drag to pan
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { val in
                                let origin = dragOrigin ?? (viewStart: zoom.viewStart, window: zoom.window)
                                if dragOrigin == nil { dragOrigin = origin }
                                let delta = -Double(val.translation.width / geo.size.width) * origin.window
                                zoom.viewStart = (origin.viewStart + delta).clamped(to: 0...(1 - zoom.window))
                            }
                            .onEnded { _ in dragOrigin = nil }
                        )
                }
            )

            // Fixed info strip below canvas
            HStack(spacing: 8) {
                if let absFrac = hoverAbsFrac {
                    let secs = absFrac * total / sr
                    Text(Self.formatTC(secs, fps: frameRate))
                        .foregroundStyle(.primary)
                } else {
                    Text("──:──:──:──")
                        .foregroundStyle(.tertiary)
                }

                Divider().frame(height: 10)

                if let lane = hoverLane {
                    let track = tracks[lane]
                    let color = Self.trackColor(track, index: lane)
                    Text(track.name)
                        .foregroundStyle(color)
                    Text("[\(track.channelFormat)]")
                        .foregroundStyle(.secondary)
                    // Show clip name under cursor
                    if let absFrac = hoverAbsFrac {
                        let hovSample = Int64(absFrac * total)
                        if let clip = track.clips.first(where: {
                            hovSample >= $0.startSample && hovSample < $0.startSample + $0.lengthSamples
                        }) {
                            Text("· \(clip.name)")
                                .foregroundStyle(color)
                        }
                    }
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if zoom.scale > 1.01 {
                    Text("×\(String(format: "%.1f", zoom.scale))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 2)
            .frame(height: 14)
        }
        .onAppear  { zoom.startMonitoring() }
        .onDisappear { zoom.stopMonitoring() }
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
