import AppKit
import SwiftUI

// MARK: - Root inspector view
// Displayed both in the Quick Look extension and the standalone app window.

struct SessionInspectorView: View {
    let session: PTXSession
    let sessionURL: URL
    var onOpenInProTools: (() -> Void)? = nil
    var onClose:         (() -> Void)? = nil

    @State private var showHiddenTracks:   Bool    = false
    @State private var showInactiveTracks: Bool    = false
    @State private var showVideoTrack:     Bool    = true
    @State private var hideMutedClips:     Bool    = false
    @State private var showMarkers:        Bool    = false
    @State private var markerSearch:       String  = ""
    @State private var overviewHeight:     CGFloat = 0     // 0 = auto-init on first render
    @State private var overviewDragStart:  CGFloat = 0
    @State private var selectedTrackNames: Set<String> = []
    @State private var trackSelectionMode: Bool   = false
    @State private var showTrackPlugins:   Bool   = true
    @StateObject private var tc = TimelineController()

    /// Max end-sample across all tracks — used to convert sample positions to timeline fractions.
    private var totalSamples: Double {
        let m = session.tracks.flatMap(\.clips).map { $0.startSample + $0.lengthSamples }.max() ?? 1
        return Double(max(m, 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            overviewSection
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sessionSetupSection
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
        InspectorSection(title: "Session Setup", systemImage: "info.circle", initiallyExpanded: false) {
            let rows: [(String, String)] = [
                ("Sample Rate",   session.sampleRate.isEmpty    ? "—" : "\(session.sampleRate) Hz"),
                ("Bit Depth",     session.bitDepth.isEmpty      ? "—" : "\(session.bitDepth)-bit"),
                ("Timecode",      session.tcFormat.isEmpty      ? "—" : session.tcFormat),
                ("Start",         session.sessionStart.isEmpty  ? "—" : session.sessionStart),
                ("Duration",      session.sessionLength.isEmpty ? "—" : session.sessionLength),
                ("Tracks",        "\(session.tracks.filter { $0.type == .audio }.count)"),
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
        let hasMuted    = session.tracks.contains { $0.clips.contains { $0.isMuted } }
        let hasMarkers  = session.memoryLocations.contains { $0.samplePosition > 0 }
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
        return InspectorSection(title: "Overview", systemImage: "chart.bar.xaxis") {
            if clippedTracks.isEmpty {
                PlaceholderRow(text: "No clip position data — binary block decoder pending")
            } else {
                let videoCount  = clippedTracks.filter { $0.type == .video }.count
                let otherCount  = clippedTracks.count - videoCount
                // Base lane heights at scale 1.0 (video=16, audio=8, gap=2)
                let baseLanesH  = CGFloat(videoCount) * 16 + CGFloat(otherCount) * 8
                               + CGFloat(max(0, videoCount + otherCount - 1)) * 2
                // overhead = row1(24) + hover row(24) + sel row(24) + checkbox row(28, if shown) + ruler(30) + padding(8)
                let overhead: CGFloat = (hasHidden || hasInactive || hasVideo || hasMuted || hasMarkers) ? 138 : 110
                // Auto-init height on first render: fit all tracks at scale 1, capped at 300
                let effectiveH: CGFloat = {
                    if overviewHeight == 0 {
                        let h = min(baseLanesH + overhead, 300)
                        DispatchQueue.main.async { overviewHeight = h }
                        return h
                    }
                    return overviewHeight
                }()
                // vScale: stretch to fill when few tracks; never compress (scroll handles overflow)
                let scrollableH = effectiveH - overhead
                let vScale = baseLanesH > 0 ? max(1.0, scrollableH / baseLanesH) : 1.0

                SessionTimelineView(tc: tc,
                                    tracks: clippedTracks,
                                    allTracksSamples: totalSamples,
                                    sampleRate: sr,
                                    frameRate: session.frameRate,
                                    tcFormat:  session.tcFormat,
                                    verticalScale: vScale,
                                    resolvedFiles: session.resolvedAudioFiles,
                                    memoryLocations: session.memoryLocations,
                                    hasHidden:   hasHidden,
                                    hasInactive: hasInactive,
                                    hasVideo:    hasVideo,
                                    hasMuted:    hasMuted,
                                    hasMarkers:  hasMarkers,
                                    showHidden:    $showHiddenTracks,
                                    showInactive:  $showInactiveTracks,
                                    showVideo:     $showVideoTrack,
                                    hideMuted:     $hideMutedClips,
                                    showMarkers:   $showMarkers,
                                    overviewHeight: $overviewHeight)
                    .frame(height: effectiveH)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                // Drag handle — pull to resize
                OverviewResizeHandle(height: $overviewHeight, dragStart: $overviewDragStart)
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Tracks

    private var tracksSection: some View {
        let audioTracks = session.tracks.filter { $0.type == .audio }
        let hasPlugins  = session.tracks.contains { !$0.plugins.isEmpty }
        return InspectorSection(title: "Tracks", systemImage: "slider.horizontal.3",
                         count: session.tracks.count, initiallyExpanded: false) {
            if session.tracks.isEmpty {
                PlaceholderRow(text: "No tracks found")
            } else {
                // ── Toolbar ────────────────────────────────────────────────────
                HStack(spacing: 8) {
                    // Plug-ins toggle — only shown when at least one track has plugins
                    if hasPlugins {
                        Toggle(isOn: $showTrackPlugins) {
                            Text("Plug-ins").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }

                    Spacer()

                    if trackSelectionMode {
                        // Select All / None
                        Button(selectedTrackNames.count == audioTracks.count ? "None" : "All") {
                            if selectedTrackNames.count == audioTracks.count {
                                selectedTrackNames.removeAll()
                            } else {
                                selectedTrackNames = Set(audioTracks.map(\.name))
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        // Export button — only active when tracks are selected
                        Button {
                            let names = session.tracks
                                .filter { selectedTrackNames.contains($0.name) }
                                .map(\.name)
                            if let url = PTXParser.writeEDL(session: session,
                                                            sessionURL: sessionURL,
                                                            trackNames: names) {
                                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                            }
                        } label: {
                            Label("Export EDL\(selectedTrackNames.isEmpty ? "" : " (\(selectedTrackNames.count))")",
                                  systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(selectedTrackNames.isEmpty)

                        // Done
                        Button("Done") {
                            trackSelectionMode = false
                            selectedTrackNames.removeAll()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        if !audioTracks.isEmpty {
                            Button {
                                trackSelectionMode = true
                            } label: {
                                Label("EDL Export…", systemImage: "film.stack")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)

                // ── Track rows ─────────────────────────────────────────────────
                ForEach(session.tracks, id: \.index) { track in
                    SelectableTrackRow(
                        track: track,
                        isSelected: selectedTrackNames.contains(track.name),
                        selectionMode: trackSelectionMode,
                        showPlugins: showTrackPlugins,
                        onToggle: {
                            if selectedTrackNames.contains(track.name) {
                                selectedTrackNames.remove(track.name)
                            } else {
                                selectedTrackNames.insert(track.name)
                            }
                        }
                    )
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
                         count: session.plugins.count, initiallyExpanded: false) {
            if session.plugins.isEmpty {
                PlaceholderRow(text: "No plug-ins found")
            } else {
                ForEach(session.plugins, id: \.self) { plugin in
                    ListRow(text: plugin, systemImage: "puzzlepiece")
                }
            }
        }
    }

    // MARK: - Memory Locations

    private var memoryLocationsSection: some View {
        let sr       = Double(session.sampleRate) ?? 48000.0
        let fps      = session.frameRate
        let total    = totalSamples
        let filtered = markerSearch.isEmpty
            ? session.memoryLocations
            : session.memoryLocations.filter { $0.name.localizedCaseInsensitiveContains(markerSearch) }
        return InspectorSection(title: "Memory Locations", systemImage: "mappin.and.ellipse",
                                count: session.memoryLocations.count, initiallyExpanded: false) {
            if session.memoryLocations.isEmpty {
                PlaceholderRow(text: "No memory locations")
            } else {
                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField("Search", text: $markerSearch)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !markerSearch.isEmpty {
                        Button { markerSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)

                if filtered.isEmpty {
                    PlaceholderRow(text: "No results for \"\(markerSearch)\"")
                } else {
                    ForEach(filtered, id: \.number) { loc in
                        let hasFrac = loc.samplePosition > 0 && total > 1
                        let frac    = hasFrac ? Double(loc.samplePosition) / total : 0.0
                        Button {
                            guard hasFrac else { return }
                            tc.jumpTo(frac)
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(loc.number)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                Text(loc.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if hasFrac {
                                    Text(Self.formatTC(samples: loc.samplePosition, sr: sr, fps: fps))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasFrac)
                    }
                }
            }
        }
    }

    private static func formatTC(samples: Int64, sr: Double, fps: Double) -> String {
        guard sr > 0, fps > 0, samples >= 0 else { return "—" }
        let totalFrames = Int64((Double(samples) / sr * fps).rounded())
        let fr  = Int64(fps.rounded())
        let f   = totalFrames % fr
        let sec = (totalFrames / fr) % 60
        let min = (totalFrames / fr / 60) % 60
        let hr  = totalFrames / fr / 3600
        return String(format: "%d:%02d:%02d:%02d", hr, min, sec, f)
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

private struct SelectableTrackRow: View {
    let track: PTXTrack
    let isSelected: Bool
    let selectionMode: Bool
    let showPlugins: Bool
    let onToggle: () -> Void

    var body: some View {
        let dimmed     = track.isHidden || track.isInactive
        let canSelect  = track.type == .audio && selectionMode
        let leadingPad = selectionMode ? 38.0 : 22.0   // extra space for checkbox when in mode

        Button(action: { if canSelect { onToggle() } }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    // Leading icon: checkbox (selection mode, audio) or track-type icon
                    if selectionMode && track.type == .audio {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                            .frame(width: 16)
                    } else {
                        Image(systemName: track.type.systemImage)
                            .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : track.type.tintColor)
                            .frame(width: 16)
                    }

                    // In selection mode, show type icon after the checkbox
                    if selectionMode && track.type == .audio {
                        Image(systemName: track.type.systemImage)
                            .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                            .frame(width: 14)
                    }

                    Text(track.name)
                        .font(.subheadline)
                        .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .italic(track.isInactive)

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

                    Spacer()

                    Text(track.channelFormat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Plugin pills
                if showPlugins && !track.plugins.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(track.plugins, id: \.self) { plugin in
                                Text(plugin)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color(nsColor: .separatorColor).opacity(0.5))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.leading, leadingPad)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, canSelect ? 4 : 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected && selectionMode ? Color.accentColor.opacity(0.07) : Color.clear)
        .animation(.easeInOut(duration: 0.12), value: selectionMode)
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

// MARK: - Overview resize handle

private struct OverviewResizeHandle: View {
    @Binding var height:     CGFloat
    @Binding var dragStart:  CGFloat

    var body: some View {
        ZStack {
            Color(nsColor: .separatorColor).opacity(0.25)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 32, height: 3)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    if dragStart == 0 { dragStart = height }
                    height = max(50, min(600, dragStart + val.translation.height))
                }
                .onEnded { _ in dragStart = 0 }
        )
        .padding(.bottom, 4)
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
    @Published var selStart:    Double? = nil   // cursor or selection start
    @Published var selEnd:      Double? = nil   // nil = cursor only
    @Published var selTrack:    Int?    = nil   // selected track (start of range)
    @Published var selTrackEnd: Int?    = nil   // non-nil when drag spans multiple tracks

    // Track expansion (E key toggles)
    @Published var expandedTracks: Set<Int> = []

    // Interaction context (not published — used by key handler only)
    var isHovering:   Bool    = false
    var isFocused:    Bool    = false
    var hoverAbsFrac: Double? = nil

    // Signal to view to open the TC entry popover (numpad *)
    @Published var openTCEntry: Bool = false

    // Navigation context — set by view on appear
    var tracks:       [PTXTrack] = []
    var totalSamples: Double     = 1.0
    var hideMuted:    Bool       = false

    private var keyMonitor:      Any?
    private var scrollMonitor:   Any?
    private var magnifyMonitor:  Any?

    var window: Double { 1.0 / scale }

    func startMonitoring() {
        guard keyMonitor == nil else { return }

        // Scroll wheel: horizontal = pan, Cmd+vertical = zoom
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isHovering || self.isFocused else { return event }
            let mods = event.modifierFlags
            if mods.contains(.command) {
                // Cmd+scroll → zoom (vertical delta drives scale)
                let delta = Double(event.scrollingDeltaY)
                if abs(delta) > 0.5 {
                    if delta > 0 { self.zoomIn(anchor: self.hoverAbsFrac) }
                    else         { self.zoomOut(anchor: self.hoverAbsFrac) }
                }
                return nil
            } else {
                // Horizontal scroll → pan timeline; vertical → pass through to ScrollView
                let dx = Double(event.scrollingDeltaX)
                let dy = Double(event.scrollingDeltaY)
                if abs(dx) > abs(dy) && abs(dx) > 0.1 {
                    let delta = dx / 300.0 * self.window
                    self.viewStart = (self.viewStart + delta).clamped(to: 0...(1 - self.window))
                    return nil
                }
            }
            return event
        }

        // Trackpad pinch → horizontal zoom centred on cursor
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, self.isHovering || self.isFocused else { return event }
            let factor = 1.0 + Double(event.magnification)
            let anchor = self.hoverAbsFrac ?? (self.viewStart + self.window / 2)
            let newSc  = (self.scale * factor).clamped(to: 1...4096)
            let newWin = 1.0 / newSc
            self.viewStart = (anchor - newWin / 2).clamped(to: 0...(1 - newWin))
            self.scale     = newSc
            return nil
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isHovering || self.isFocused else { return event }
            // Numpad * (keyCode 67) → open TC entry popover (mirrors Pro Tools behaviour)
            if event.keyCode == 67 {
                self.openTCEntry = true
                return nil
            }
            guard let ch = event.charactersIgnoringModifiers else { return event }
            let mods   = event.modifierFlags
            switch ch {
            case "t":      self.zoomIn();  return nil
            case "r":      self.zoomOut(); return nil
            case "e", "E":
                if let idx = self.selTrack {
                    if self.expandedTracks.contains(idx) { self.expandedTracks.remove(idx) }
                    else { self.expandedTracks.insert(idx) }
                }
                return nil
            case "\u{1b}": self.clearSelection();        return nil  // Escape
            case "\u{f729}":                                        // Home → go to start
                self.selStart = 0.0; self.selEnd = nil; self.viewStart = 0.0
                return nil
            case "\u{f72b}":                                        // End → go to end
                self.selStart = 1.0; self.selEnd = nil
                let w = self.window; self.viewStart = (1.0 - w).clamped(to: 0...1)
                return nil
            case "p":      self.prevTrack();             return nil
            case ";":      self.nextTrack();             return nil
            case "l":      self.prevBoundary();          return nil
            case "'":      self.nextBoundary();          return nil
            case "\t":
                if mods.contains(.option) { self.nextClipEnd()    }
                else if mods.contains(.shift) { self.prevBoundary() }
                else                          { self.nextBoundary() }
                return nil
            default: return event
            }
        }
    }

    func stopMonitoring() {
        [keyMonitor, scrollMonitor, magnifyMonitor].forEach {
            if let m = $0 { NSEvent.removeMonitor(m) }
        }
        keyMonitor = nil; scrollMonitor = nil; magnifyMonitor = nil
    }

    // MARK: Zoom

    func zoomIn(anchor: Double? = nil) {
        let a      = anchor ?? selStart ?? (viewStart + window / 2)
        let newSc  = min(scale * 1.5, 4096)
        let newWin = 1.0 / newSc
        viewStart  = (a - newWin / 2).clamped(to: 0...(1 - newWin))
        scale      = newSc
    }

    func zoomOut(anchor: Double? = nil) {
        let newSc = max(scale / 1.5, 1.0)
        guard newSc > 1.0 else { viewStart = 0; scale = 1.0; return }
        let a      = anchor ?? selStart ?? (viewStart + window / 2)
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
        selStart = nil; selEnd = nil; selTrack = nil; selTrackEnd = nil
    }

    // MARK: Track navigation

    func nextTrack() {
        guard !tracks.isEmpty else { return }
        selTrack = min(tracks.count - 1, (selTrack ?? -1) + 1)
        selTrackEnd = nil
    }

    func prevTrack() {
        guard !tracks.isEmpty else { return }
        selTrack = max(0, (selTrack ?? tracks.count) - 1)
        selTrackEnd = nil
    }

    // MARK: Clip navigation
    // Falls back to track 0 when no track is selected, so Tab/Shift+Tab
    // work immediately without requiring a prior click.

    func nextClipStart() {
        let idx = selTrack ?? 0
        guard !tracks.isEmpty else { return }
        let cursor = selStart ?? 0
        guard let next = TimelineNav.nextClipStart(tracks: tracks, total: totalSamples,
                                                    trackIdx: idx, cursor: cursor,
                                                    hideMuted: hideMuted) else { return }
        selTrack = idx; selStart = next; selEnd = nil
        ensureVisible(next)
    }

    func prevClipStart() {
        let idx = selTrack ?? 0
        guard !tracks.isEmpty else { return }
        let cursor = selStart ?? 1
        guard let prev = TimelineNav.prevClipStart(tracks: tracks, total: totalSamples,
                                                    trackIdx: idx, cursor: cursor,
                                                    hideMuted: hideMuted) else { return }
        selTrack = idx; selStart = prev; selEnd = nil
        ensureVisible(prev)
    }

    func nextClipEnd() {
        let idx = selTrack ?? 0
        guard !tracks.isEmpty else { return }
        let cursor = selStart ?? 0
        guard let next = TimelineNav.nextClipEnd(tracks: tracks, total: totalSamples,
                                                  trackIdx: idx, cursor: cursor,
                                                  hideMuted: hideMuted) else { return }
        selTrack = idx; selStart = next; selEnd = nil
        ensureVisible(next)
    }

    func nextBoundary() {
        guard !tracks.isEmpty else { return }
        let cursor = selStart ?? 0
        let lo = min(selTrack ?? 0, selTrackEnd ?? selTrack ?? 0)
        let hi = max(selTrack ?? 0, selTrackEnd ?? selTrack ?? 0)
        var best: Double? = nil
        for idx in lo...hi {
            if let b = TimelineNav.nextBoundary(tracks: tracks, total: totalSamples,
                                                trackIdx: idx, cursor: cursor,
                                                hideMuted: hideMuted) {
                if best == nil || b < best! { best = b }
            }
        }
        guard let next = best else { return }
        selStart = next; selEnd = nil
        ensureVisible(next)
    }

    func prevBoundary() {
        guard !tracks.isEmpty else { return }
        let cursor = selStart ?? 1
        let lo = min(selTrack ?? 0, selTrackEnd ?? selTrack ?? 0)
        let hi = max(selTrack ?? 0, selTrackEnd ?? selTrack ?? 0)
        var best: Double? = nil
        for idx in lo...hi {
            if let b = TimelineNav.prevBoundary(tracks: tracks, total: totalSamples,
                                                trackIdx: idx, cursor: cursor,
                                                hideMuted: hideMuted) {
                if best == nil || b > best! { best = b }
            }
        }
        guard let prev = best else { return }
        selStart = prev; selEnd = nil
        ensureVisible(prev)
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
    @ObservedObject var tc: TimelineController

    let tracks: [PTXTrack]
    var allTracksSamples: Double = 0   // max end-sample across ALL tracks (incl. hidden/inactive)
    let sampleRate: Double
    var frameRate: Double = 30
    var tcFormat:  String = ""
    var verticalScale: CGFloat = 1.0
    var resolvedFiles: [ResolvedAudioFile] = []
    var memoryLocations: [PTXMemoryLocation] = []

    // Track filter toggles shown in the checkbox row
    var hasHidden:   Bool = false
    var hasInactive: Bool = false
    var hasVideo:    Bool = false
    var hasMuted:    Bool = false
    var hasMarkers:  Bool = false
    @Binding var showHidden:    Bool
    @Binding var showInactive:  Bool
    @Binding var showVideo:     Bool
    @Binding var hideMuted:     Bool
    @Binding var showMarkers:   Bool
    @Binding var overviewHeight: CGFloat

    // Hover state (view-owned for rendering; tc.hoverAbsFrac mirrors it for key handler)
    @State private var hoverAbsFrac:      Double?  = nil
    @State private var hoverLane:         Int?     = nil
    @State private var hoverClip:         PTXClip? = nil
    @State private var hoverClipTrackIdx: Int?     = nil

    // Selected clip — local state so changes don't trigger tc.objectWillChange
    // (which would force an expensive canvas repaint)
    @State private var selectedClip:         PTXClip? = nil
    @State private var selectedClipTrackIdx: Int?     = nil

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
    private static let rulerH:     CGFloat = 30

    private static func trackLaneH(_ track: PTXTrack) -> CGFloat {
        track.type == .video ? videoLaneH : audioLaneH
    }
    private func scaledLaneH(_ track: PTXTrack, index: Int) -> CGFloat {
        let base = Self.trackLaneH(track) * verticalScale
        return tc.expandedTracks.contains(index) ? base * 4 : base
    }
    private static func trackColor(_ track: PTXTrack, index: Int) -> Color {
        track.type == .video ? videoColor : palette[index % palette.count]
    }

    /// Total pixel height of all track lanes at current scale (no ruler).
    private var totalLaneHeight: CGFloat {
        var h: CGFloat = 0
        for (i, t) in tracks.enumerated() {
            h += scaledLaneH(t, index: i)
            if i < tracks.count - 1 { h += Self.laneGap }
        }
        return max(h, 1)
    }

    /// Returns the track index at a given y position within the lane canvas.
    private func laneIndex(at y: CGFloat, availH: CGFloat) -> Int? {
        var top: CGFloat = 0
        for (i, track) in tracks.enumerated() {
            let h = scaledLaneH(track, index: i)
            if y >= top && y < top + h { return i }
            top += h + Self.laneGap
            if top > availH { break }
        }
        return nil
    }

    var body: some View {
        // Use allTracksSamples if provided so ruler markers and the cursor always share
        // the same denominator, even when some tracks are hidden/filtered from the canvas.
        let visibleMax = Double(max(
            tracks.flatMap(\.clips).map { $0.startSample + $0.lengthSamples }.max() ?? 1, 1
        ))
        let sr    = max(sampleRate, 1)
        let total = allTracksSamples > 0 ? allTracksSamples : visibleMax

        VStack(spacing: 0) {
            // ── Row 1: TC cursor | track label | zoom ────────────────────────
            HStack(spacing: 8) {
                // TC position / entry button
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
                                let samp = Int64((s * total).rounded())
                                Text("\(Self.formatTC(s * total / sr, fps: frameRate))  (\(samp))")
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
                    .frame(width: 160, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Click or press numpad * to go to timecode")
                .popover(isPresented: $showTCEntry, arrowEdge: .bottom) {
                    TCEntryPopover(text: $tcEntryText) { text in
                        if let frac = TimelineNav.parseTCFrac(text, fps: frameRate,
                                                              totalSamples: total, sampleRate: sr) {
                            tc.jumpTo(frac)
                        }
                        showTCEntry = false
                    }
                }

                Divider().frame(height: 14)

                // Track name + format
                let displayIdx = tc.selTrack ?? hoverLane
                if let idx = displayIdx, idx < tracks.count {
                    let track = tracks[idx]
                    let color = Self.trackColor(track, index: idx)
                    let fmtLabel: String = {
                        guard track.type == .video else { return track.channelFormat }
                        return tcFormat.isEmpty ? "Video" : "Video · \(tcFormat)"
                    }()
                    Text(track.name).foregroundStyle(color)
                    Text("[\(fmtLabel)]").foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }

                Spacer()

                // H zoom
                HStack(spacing: 4) {
                    Text("H:").foregroundStyle(.secondary)
                    Button { tc.zoomOut() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).controlSize(.mini)
                    Text(tc.scale > 1.01 ? "×\(String(format: "%.1f", tc.scale))" : "Fit")
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .center)
                    Button { tc.zoomIn() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).controlSize(.mini)
                }

                Divider().frame(height: 14)

                // V zoom
                HStack(spacing: 4) {
                    Text("V:").foregroundStyle(.secondary)
                    Button { overviewHeight = max(50, overviewHeight / 1.5) } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless).controlSize(.mini)
                    Button { overviewHeight = min(600, overviewHeight * 1.5) } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless).controlSize(.mini)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)

            // ── Row 2: hover clip (ephemeral — follows cursor) ───────────────
            clipInfoRow(
                clip: hoverClip, trackIdx: hoverClipTrackIdx,
                label: "HOVER", sr: sr, isSelected: false
            )

            // ── Row 3: selected clip (persistent — set by click) ─────────────
            clipInfoRow(
                clip: selectedClip, trackIdx: selectedClipTrackIdx,
                label: "SEL", sr: sr, isSelected: true
            )

            // ── Checkbox row ─────────────────────────────────────────────────
            if hasHidden || hasInactive || hasVideo || hasMuted || hasMarkers {
                HStack(spacing: 12) {
                    if hasHidden {
                        Toggle(isOn: $showHidden) {
                            Text("Show hidden").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if hasInactive {
                        Toggle(isOn: $showInactive) {
                            Text("Show inactive").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if hasVideo {
                        Toggle(isOn: $showVideo) {
                            Text("Show video").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if hasMuted {
                        Toggle(isOn: $hideMuted) {
                            Text("Hide muted").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if hasMarkers {
                        Toggle(isOn: $showMarkers) {
                            Text("Show markers").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            // ── Ruler (adaptive tick spacing) ─────────────────────────────────
            Canvas { ctx, size in
                let vStart      = tc.viewStart
                let vWindow     = tc.window
                let visibleSecs = vWindow * total / sr

                // Baseline rule
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 0.5)),
                         with: .color(.secondary.opacity(0.35)))

                // ── TC ticks — top zone (y 0…18) ──────────────────────────────
                let fps = frameRate
                let stepCandidates: [Double] = [
                    1/fps, 2/fps, 5/fps, 10/fps,
                    1, 2, 5, 10, 30, 60, 120, 300, 600, 1800, 3600
                ]
                let step = stepCandidates.last { visibleSecs / $0 >= 3 } ?? stepCandidates.last!

                let winStartSec  = vStart * total / sr
                let winEndSec    = (vStart + vWindow) * total / sr
                let firstTickSec = ceil(winStartSec / step) * step
                var tickSec      = firstTickSec
                while tickSec <= winEndSec + step * 0.001 {
                    let frac = tickSec / (total / sr)
                    let x    = CGFloat((frac - vStart) / vWindow) * size.width
                    guard x >= -2 && x <= size.width + 2 else { tickSec += step; continue }
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: 5)),
                             with: .color(.secondary.opacity(0.5)))
                    let anchor: UnitPoint = x < 20 ? .topLeading : (x > size.width - 20 ? .topTrailing : .top)
                    ctx.draw(
                        Text(Self.formatTC(tickSec, fps: fps))
                            .font(.system(size: 9).monospacedDigit()),
                        at: CGPoint(x: x, y: 6),
                        anchor: anchor
                    )
                    tickSec += step
                }

                // ── Memory location markers — bottom zone (y 18…30) ───────────
                if showMarkers {
                    var prevLabelX: CGFloat = -100
                    for loc in memoryLocations where loc.samplePosition > 0 {
                        let frac = Double(loc.samplePosition) / total
                        let x    = CGFloat((frac - vStart) / vWindow) * size.width
                        guard x >= -1, x <= size.width + 1 else { continue }
                        // Full-height orange line (hairline, behind tick labels)
                        ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                                 with: .color(.orange.opacity(0.55)))
                        // Marker name in the bottom strip — skip if too close to previous
                        if x - prevLabelX > 34 {
                            let anchor: UnitPoint = x < 20 ? .bottomLeading
                                : x > size.width - 20 ? .bottomTrailing : .bottomLeading
                            ctx.draw(
                                Text(loc.name)
                                    .font(.system(size: 8).weight(.medium))
                                    .foregroundColor(.orange),
                                at: CGPoint(x: x + 3, y: size.height - 1),
                                anchor: anchor
                            )
                            prevLabelX = x
                        }
                    }
                }
            }
            .frame(height: Self.rulerH)
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onEnded { val in
                                    let x    = val.location.x
                                    let raw  = (tc.viewStart + Double(x / geo.size.width) * tc.window)
                                        .clamped(to: 0...1)
                                    // Snap to nearest visible marker within 12px
                                    var dest = raw
                                    for loc in memoryLocations where loc.samplePosition > 0 {
                                        let mFrac = Double(loc.samplePosition) / total
                                        let mx    = CGFloat((mFrac - tc.viewStart) / tc.window) * geo.size.width
                                        if abs(mx - x) < 12 {
                                            let d = abs(mFrac - raw)
                                            if d < abs(dest - raw) || dest == raw { dest = mFrac }
                                        }
                                    }
                                    tc.jumpTo(dest)
                                    selectedClip         = nil
                                    selectedClipTrackIdx = nil
                                    tc.isFocused            = true
                                }
                        )
                }
            )

            // ── Scrollable lane area ──────────────────────────────────────────
            ScrollView(.vertical, showsIndicators: false) {
              Canvas { ctx, size in
                let vStart  = tc.viewStart
                let vWindow = tc.window
                let availH  = size.height

                // Lanes + clips
                let selLo = min(tc.selTrack ?? -1, tc.selTrackEnd ?? tc.selTrack ?? -1)
                let selHi = max(tc.selTrack ?? -1, tc.selTrackEnd ?? tc.selTrack ?? -1)

                // Visible window in sample space — used for early-exit in clip loop
                let winStartSamp = Int64((vStart * total).rounded(.down))
                let winEndSamp   = Int64(((vStart + vWindow) * total).rounded(.up))

                var laneY: CGFloat = 0
                for (i, track) in tracks.enumerated() {
                    let thisLaneH  = scaledLaneH(track, index: i)
                    let color      = Self.trackColor(track, index: i)
                    let isSelected = selLo >= 0 && i >= selLo && i <= selHi
                    let bgAlpha: Double = isSelected ? 0.18 : 0.03

                    ctx.fill(
                        Path(CGRect(x: 0, y: laneY, width: size.width, height: thisLaneH)),
                        with: .color(color.opacity(bgAlpha))
                    )

                    // PT playlists are in time order, so we can break once past the window.
                    for clip in track.clips {
                        guard clip.lengthSamples > 0 else { continue }
                        // Past visible window — clips are sorted, remaining clips also invisible
                        if clip.startSample >= winEndSamp { break }
                        // Before visible window
                        if clip.startSample + clip.lengthSamples <= winStartSamp { continue }
                        if hideMuted && clip.isMuted { continue }

                        let clipFracStart = Double(clip.startSample) / total
                        let clipFracLen   = Double(clip.lengthSamples) / total
                        let x = CGFloat((clipFracStart - vStart) / vWindow) * size.width
                        let w = max(1, CGFloat(clipFracLen / vWindow) * size.width)
                        let fillAlpha: Double = clip.isMuted ? 0.28 : 0.88
                        let clipRect = CGRect(x: x, y: laneY, width: w, height: thisLaneH)

                        ctx.fill(Path(clipRect), with: .color(color.opacity(fillAlpha)))

                        // Stroke and label only for clips wider than 2px
                        if w >= 2 {
                            let edgeAlpha: Double = clip.isMuted ? 0.45 : 1.0
                            ctx.stroke(Path(clipRect), with: .color(color.opacity(edgeAlpha)),
                                       style: StrokeStyle(lineWidth: 1))
                            if w > 32 {
                                let fontSize: CGFloat = track.type == .video ? 8 : 6
                                let labelAlpha: Double = clip.isMuted ? 0.5 : 1.0
                                ctx.draw(
                                    Text(clip.name)
                                        .font(.system(size: fontSize).bold())
                                        .foregroundColor(.white.opacity(labelAlpha)),
                                    in: CGRect(x: x + 3,
                                               y: laneY + (thisLaneH - fontSize) / 2 - 1,
                                               width: w - 6, height: fontSize + 2)
                                )
                            }
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
              .frame(height: totalLaneHeight)
              .overlay(
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .contextMenu {
                            // Find the clip under the last known hover position
                            if let laneIdx = hoverLane,
                               let absFrac = hoverAbsFrac,
                               laneIdx < tracks.count {
                                let hovSample = Int64(absFrac * total)
                                if let clip = tracks[laneIdx].clips.first(where: {
                                    hovSample >= $0.startSample
                                        && hovSample < $0.startSample + $0.lengthSamples
                                }) {
                                    let resolved = resolvedFiles.first { $0.name == clip.sourceFile }
                                    if let url = resolved?.url {
                                        Button("Reveal \"\(clip.sourceFile)\" in Finder") {
                                            NSWorkspace.shared.selectFile(
                                                url.path,
                                                inFileViewerRootedAtPath: "")
                                        }
                                    } else {
                                        Text(clip.name)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                tc.isHovering   = true
                                let screenFrac  = Double(loc.x / geo.size.width).clamped(to: 0...1)
                                let absFrac     = tc.viewStart + screenFrac * tc.window
                                hoverAbsFrac    = absFrac
                                tc.hoverAbsFrac = absFrac
                                let lane        = laneIndex(at: loc.y, availH: geo.size.height)
                                hoverLane       = lane
                                // Find clip under cursor
                                if let idx = lane, idx < tracks.count {
                                    let samp = Int64(absFrac * total)
                                    let clip = tracks[idx].clips.first(where: {
                                        (!hideMuted || !$0.isMuted) &&
                                        samp >= $0.startSample &&
                                        samp < $0.startSample + $0.lengthSamples
                                    })
                                    hoverClip         = clip
                                    hoverClipTrackIdx = clip != nil ? idx : nil
                                } else {
                                    hoverClip         = nil
                                    hoverClipTrackIdx = nil
                                }
                            case .ended:
                                tc.isHovering     = false
                                tc.hoverAbsFrac   = nil
                                hoverAbsFrac      = nil
                                hoverLane         = nil
                                hoverClip         = nil
                                hoverClipTrackIdx = nil
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
                                                                     availH: geo.size.height)
                                        }
                                        tc.selEnd = curFrac
                                        let curLane = laneIndex(at: val.location.y,
                                                                 availH: geo.size.height)
                                        tc.selTrackEnd = curLane != tc.selTrack ? curLane : nil
                                    }
                                }
                                .onEnded { val in
                                    let dist = hypot(val.translation.width, val.translation.height)
                                    if dist < 3 {
                                        // Click: place cursor, or select clip if one is under the click
                                        let frac     = (Double(val.location.x / geo.size.width)
                                            * tc.window + tc.viewStart).clamped(to: 0...1)
                                        let clickLane = laneIndex(at: val.location.y, availH: geo.size.height)
                                        tc.selTrackEnd = nil
                                        tc.isFocused   = true
                                        tc.selTrack    = clickLane

                                        // Find clip under click
                                        let clickedClip: PTXClip? = {
                                            guard let idx = clickLane, idx < tracks.count else { return nil }
                                            let samp = Int64(frac * total)
                                            return tracks[idx].clips.first(where: {
                                                (!hideMuted || !$0.isMuted) &&
                                                samp >= $0.startSample &&
                                                samp < $0.startSample + $0.lengthSamples
                                            })
                                        }()

                                        if let clip = clickedClip, let idx = clickLane {
                                            // Place cursor at clip in-point; info row shows full in/out
                                            tc.selStart              = Double(clip.startSample) / total
                                            tc.selEnd                = nil
                                            selectedClip          = clip
                                            selectedClipTrackIdx  = idx
                                        } else {
                                            // Empty space → cursor only
                                            tc.selStart             = frac
                                            tc.selEnd               = nil
                                            selectedClip         = nil
                                            selectedClipTrackIdx = nil
                                        }
                                    } else if isDragging {
                                        // Drag selection clears any clip selection
                                        selectedClip         = nil
                                        selectedClipTrackIdx = nil
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
            } // ScrollView
        }
        .onAppear {
            tc.tracks       = tracks
            tc.totalSamples = allTracksSamples > 0 ? allTracksSamples : visibleMax
            tc.hideMuted    = hideMuted
            tc.startMonitoring()
        }
        .onDisappear { tc.stopMonitoring() }
        .onChange(of: hideMuted) { tc.hideMuted = $0 }
        // Clear selected clip when cursor is cleared (Escape key via tc.clearSelection)
        .onChange(of: tc.selStart) { if $0 == nil { selectedClip = nil; selectedClipTrackIdx = nil } }
        .onChange(of: tc.openTCEntry) { wants in
            guard wants else { return }
            tc.openTCEntry = false
            tcEntryText = tc.selStart.map { Self.formatTC($0 * total / sr, fps: frameRate) } ?? ""
            showTCEntry = true
        }
    }

    @ViewBuilder
    private func clipInfoRow(clip: PTXClip?, trackIdx: Int?,
                             label: String, sr: Double, isSelected: Bool) -> some View {
        if let clip, let tIdx = trackIdx {
            let color     = tIdx < tracks.count ? Self.trackColor(tracks[tIdx], index: tIdx) : Color.secondary
            let inTC      = Self.formatTC(Double(clip.startSample) / sr, fps: frameRate)
            let outTC     = Self.formatTC(Double(clip.startSample + clip.lengthSamples) / sr, fps: frameRate)
            let durTC     = Self.formatTC(Double(clip.lengthSamples) / sr, fps: frameRate)
            let trackName = tIdx < tracks.count ? tracks[tIdx].name : ""
            HStack(spacing: 8) {
                // Label badge
                Text(label)
                    .font(.system(size: 9).weight(.bold))
                    .foregroundStyle(isSelected ? color : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected
                                  ? color.opacity(0.18)
                                  : Color(nsColor: .separatorColor).opacity(0.5))
                    )

                // Color swatch
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? color : color.opacity(0.5))
                    .frame(width: 3, height: 14)

                // Track name
                if !trackName.isEmpty {
                    Text(trackName)
                        .foregroundStyle(isSelected ? color.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                }

                // Clip name (+ muted badge)
                Text(clip.name)
                    .foregroundStyle(isSelected ? color : Color(nsColor: .secondaryLabelColor))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if clip.isMuted {
                    Text("muted")
                        .font(.system(size: 9).weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .separatorColor).opacity(0.6)))
                }

                Spacer()

                // Timecodes — larger, clearly labelled
                HStack(spacing: 6) {
                    Label(inTC, systemImage: "arrow.right.to.line")
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text("→")
                        .foregroundStyle(.tertiary)
                    Label(outTC, systemImage: "arrow.left.to.line")
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text("· \(durTC)")
                        .foregroundStyle(.tertiary)
                }
                .labelStyle(.titleAndIcon)
            }
            .font(.system(size: 11).monospacedDigit())
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(isSelected
                ? color.opacity(0.07)
                : Color(nsColor: .separatorColor).opacity(0.05))
            .transition(.opacity)
        }
    }

    private static func formatTC(_ seconds: Double, fps: Double) -> String {
        guard seconds.isFinite, seconds >= 0, fps > 0 else { return "0:00:00:00" }
        let totalFrames = Int((seconds * fps).rounded())
        let fr  = Int(fps.rounded())
        let f   = totalFrames % fr
        let sec = (totalFrames / fr) % 60
        let min = (totalFrames / fr / 60) % 60
        let hr  = totalFrames / fr / 3600
        return String(format: "%d:%02d:%02d:%02d", hr, min, sec, f)
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
