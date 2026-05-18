import AppKit
import SwiftUI

// MARK: - Color mode (shared between main app and QL extension)

enum ColorMode: String {
    case light, dark, grm
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark, .grm: return .dark
        }
    }
}

// MARK: - Root inspector view
// Displayed both in the Quick Look extension and the standalone app window.

struct SessionInspectorView: View {
    let session: PTXSession
    let sessionURL: URL
    var onOpenInProTools: (() -> Void)? = nil
    var onRescan:        (() -> Void)? = nil
    var onClose:         (() -> Void)? = nil

    // Overview toggles
    @AppStorage("ov.showHiddenTracks")   private var showHiddenTracks:   Bool = false
    @AppStorage("ov.showInactiveTracks") private var showInactiveTracks: Bool = false
    @AppStorage("ov.showVideoTrack")     private var showVideoTrack:     Bool = true
    @AppStorage("ov.hideMutedClips")     private var hideMutedClips:     Bool = false
    @AppStorage("ov.showMarkers")        private var showMarkers:         Bool = false
    @AppStorage("ov.showEmptyTracks")    private var showEmptyTracks:     Bool = true
    // Track list toggles (separate from overview)
    @AppStorage("tl.showHiddenTracks")   private var tlShowHiddenTracks:   Bool = false
    @AppStorage("tl.showInactiveTracks") private var tlShowInactiveTracks: Bool = true
    @State private var markerSearch:         String  = ""
    @State private var hiddenTrackTypes:     Set<PTXTrackType> = []
    @State private var hideAtmosObjects:     Bool = false
    @State private var hideAtmosBeds:        Bool = false
    @State private var trackSectionExpanded:   Bool = false
    @State private var audioSectionExpanded:   Bool = false
    @State private var pluginSectionExpanded:  Bool = false
    @State private var memLocSectionExpanded:  Bool = false
    @State private var overviewHeight:   CGFloat = 0     // 0 = auto-init on first render
    @State private var availableHeight:  CGFloat = 500   // updated by GeometryReader in body
    @State private var showTrackPlugins: Bool = true
    @State private var didCheckPlugins:  Bool = false   // reset per session open
    @ObservedObject private var pluginScanner = PluginScanner.shared
    @StateObject private var tc = TimelineController()

    private var hasRoutingData: Bool {
        session.tracks.contains { $0.inputPath != nil || $0.outputPath != nil }
    }

    /// Max end-sample across all tracks — used to convert sample positions to timeline fractions.
    private var totalSamples: Double {
        let m = session.tracks.flatMap(\.clips).map { $0.startSample + $0.lengthSamples }.max() ?? 1
        return Double(max(m, 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sessionSetupSection
            Divider()
            overviewSection
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // ── Tracks ───────────────────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            if trackSectionExpanded { tracksContent }
                            Divider().padding(.horizontal, 16)
                        }
                    } header: {
                        VStack(spacing: 0) {
                            SectionHeader(title: "Tracks", systemImage: "slider.horizontal.3",
                                          count: session.tracks.count, isExpanded: $trackSectionExpanded)
                            if trackSectionExpanded {
                                trackFilterBadges
                                trackColumnHeader
                            }
                        }
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                    // ── Audio Files ───────────────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            if audioSectionExpanded { audioFilesContent }
                            Divider().padding(.horizontal, 16)
                        }
                    } header: {
                        SectionHeader(title: "Audio Files", systemImage: "waveform",
                                      count: session.audioFileNames.count, isExpanded: $audioSectionExpanded)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                    // ── Plug-Ins ──────────────────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            if pluginSectionExpanded { pluginsContent }
                            Divider().padding(.horizontal, 16)
                        }
                    } header: {
                        SectionHeader(title: "Plug-Ins Used", systemImage: "puzzlepiece.extension",
                                      count: session.plugins.count, isExpanded: $pluginSectionExpanded)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                    // ── Memory Locations ─────────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            if memLocSectionExpanded { memoryLocationsContent }
                            Divider().padding(.horizontal, 16)
                        }
                    } header: {
                        SectionHeader(title: "Memory Locations", systemImage: "mappin.and.ellipse",
                                      count: session.memoryLocations.count, isExpanded: $memLocSectionExpanded)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { availableHeight = geo.size.height }
                    .onChange(of: geo.size.height) { availableHeight = $0 }
            }
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { pluginScanner.startupCheck() }
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

            if let rescan = onRescan {
                Button(action: rescan) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reparse the session file from disk")
            }

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
        InspectorSection(title: "Session Setup", systemImage: "info.circle", initiallyExpanded: true) {
            let rows: [(String, String)] = [
                ("Sample Rate",   session.sampleRate.isEmpty    ? "—" : "\(session.sampleRate) Hz"),
                ("Bit Depth",     session.bitDepth.isEmpty      ? "—" : "\(session.bitDepth)-bit"),
                ("Timecode",      session.tcFormat.isEmpty      ? "—" : session.tcFormat),
                ("TC Start",      session.sessionStart.isEmpty  ? "—" : session.sessionStart),
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
                // Either toggle can reveal a track that is both hidden and inactive.
                (showHiddenTracks   || !$0.isHidden   || (showInactiveTracks && $0.isInactive))
                && (showInactiveTracks || !$0.isInactive || (showHiddenTracks   && $0.isHidden))
                && (showVideoTrack     || $0.type != .video)
                && (showEmptyTracks    || !$0.clips.isEmpty)
            }
            .sorted { a, b in
                // Video tracks always appear first (they anchor the timeline).
                // Everything else keeps PT mixer order (index was reset to 0…N after reorder).
                let av = a.type == .video ? 0 : 1
                let bv = b.type == .video ? 0 : 1
                if av != bv { return av < bv }
                return a.index < b.index
            }
        let sr = Double(session.sampleRate) ?? 48000.0
        // Leave at least 200 px for the collapsible sections below the overview.
        let maxH = max(100, availableHeight - 280)
        return VStack(spacing: 0) {
            InspectorSection(title: "Overview", systemImage: "chart.bar.xaxis") {
                if clippedTracks.isEmpty {
                    PlaceholderRow(text: "No tracks found")
                } else {
                    let videoCount  = clippedTracks.filter { $0.type == .video }.count
                    let otherCount  = clippedTracks.count - videoCount
                    // Base lane heights at scale 1.0 (video=16, audio=8, gap=2)
                    let baseLanesH  = CGFloat(videoCount) * 16 + CGFloat(otherCount) * 8
                                   + CGFloat(max(0, videoCount + otherCount - 1)) * 2
                    // overhead = row1(24) + hover row(24) + sel row(24) + checkbox row(28) + ruler(30) + padding(8)
                    let overhead: CGFloat = 138
                    // Auto-init height on first render: fit all tracks at scale 1, capped at 300
                    let effectiveH: CGFloat = {
                        if overviewHeight == 0 {
                            let h = min(baseLanesH + overhead, 300)
                            DispatchQueue.main.async { overviewHeight = h }
                            return h
                        }
                        return overviewHeight
                    }()
                    // Use session length from PTSL when available; fall back to last clip end.
                    // This ensures the timeline extends to the full session end, not just the last clip.
                    let clipMax = clippedTracks.flatMap(\.clips)
                        .map { $0.startSample + $0.lengthSamples }.max() ?? 0
                    let sessionMax = session.sessionLengthSamples.map { Int64($0) } ?? 0
                    let visibleMax = Double(max(max(clipMax, sessionMax), 1)) + sr * 3600
                    SessionTimelineView(tc: tc,
                                        tracks: clippedTracks,
                                        allTracksSamples: visibleMax,
                                        sampleRate: sr,
                                        frameRate: session.frameRate,
                                        tcFormat:  session.tcFormat,
                                        verticalScale: 1.0,
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
                                        showEmpty:     $showEmptyTracks,
                                        overviewHeight: $overviewHeight)
                        .frame(height: effectiveH)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
            }
            // Drag handle lives OUTSIDE InspectorSection so it's in a stable
            // container that doesn't resize during the drag gesture.
            if !clippedTracks.isEmpty {
                OverviewResizeHandle(height: $overviewHeight, maxHeight: maxH)
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Tracks

    private var presentTrackTypes: [PTXTrackType] {
        let order: [PTXTrackType] = [.audio, .instrument, .midi, .aux, .vca, .master, .folder, .video, .unknown]
        return order.filter { t in session.tracks.contains { $0.type == t } }
    }

    @ViewBuilder
    private func atmosFilterBadge(label: String, color: Color, hidden: Binding<Bool>) -> some View {
        Button { hidden.wrappedValue.toggle() } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hidden.wrappedValue ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(hidden.wrappedValue
                    ? Color(nsColor: .separatorColor).opacity(0.3)
                    : color.opacity(0.15)))
                .overlay(Capsule().strokeBorder(
                    hidden.wrappedValue ? Color.clear : color.opacity(0.5),
                    lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.1), value: hidden.wrappedValue)
    }

    @ViewBuilder
    private var trackFilterBadges: some View {
        if presentTrackTypes.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(presentTrackTypes, id: \.self) { type in
                        let hidden = hiddenTrackTypes.contains(type)
                        Button {
                            if hidden { hiddenTrackTypes.remove(type) }
                            else      { hiddenTrackTypes.insert(type) }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: type.systemImage).font(.system(size: 8))
                                Text(type.filterLabel).font(.system(size: 10))
                            }
                            .foregroundStyle(hidden ? AnyShapeStyle(.tertiary) : type.tintColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(hidden
                                ? Color(nsColor: .separatorColor).opacity(0.3)
                                : Color(nsColor: .separatorColor).opacity(0.55)))
                            .overlay(Capsule().strokeBorder(
                                hidden ? Color.clear : Color(nsColor: .separatorColor).opacity(0.4),
                                lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.1), value: hidden)
                    }
                    let hasAtmosObjects = session.tracks.contains { $0.isAtmosObject }
                    let hasAtmosBeds    = session.tracks.contains { $0.isAtmosBed }
                    if hasAtmosObjects {
                        atmosFilterBadge(label: "OBJ", color: .purple, hidden: $hideAtmosObjects)
                    }
                    if hasAtmosBeds {
                        atmosFilterBadge(label: "BED", color: .orange, hidden: $hideAtmosBeds)
                    }
                    if !hiddenTrackTypes.isEmpty || hideAtmosObjects || hideAtmosBeds {
                        Button("Show all") {
                            hiddenTrackTypes.removeAll()
                            hideAtmosObjects = false
                            hideAtmosBeds    = false
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var hasAtmosData: Bool {
        session.tracks.contains { $0.isAtmosObject || $0.isAtmosBed }
    }

    private var trackColumnHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 24)  // icon (16) + gap (8)
            Text("Name").font(.caption2).foregroundStyle(.tertiary)
                .frame(width: 200, alignment: .leading)
            Text("Format").font(.caption2).foregroundStyle(.tertiary)
                .frame(width: 55, alignment: .center)
            if hasRoutingData {
                Text("Input").font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: 110, alignment: .center)
                Text("Output").font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: 110, alignment: .center)
            }
            if hasAtmosData {
                Text("Atmos").font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: 65, alignment: .center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var tracksContent: some View {
        let hasHiddenTracks   = session.tracks.contains { $0.isHidden }
        let hasInactiveTracks = session.tracks.contains { $0.isInactive }
        let visibleTracks = session.tracks.filter {
            !hiddenTrackTypes.contains($0.type)
            && (tlShowHiddenTracks   || !$0.isHidden)
            && (tlShowInactiveTracks || !$0.isInactive)
            && (!hideAtmosObjects    || !$0.isAtmosObject)
            && (!hideAtmosBeds       || !$0.isAtmosBed)
        }
        let hasPlugins   = session.tracks.contains { !$0.plugins.isEmpty }
        let totalCount   = session.tracks.count
        let visibleCount = visibleTracks.count
        let showRouting  = hasRoutingData
        if session.tracks.isEmpty {
            PlaceholderRow(text: "No tracks found")
        } else {
            // ── Toolbar (toggles) ──────────────────────────────────────────
            if hasPlugins || hasHiddenTracks || hasInactiveTracks {
                HStack(spacing: 8) {
                    if hasPlugins {
                        Toggle(isOn: $showTrackPlugins) {
                            Text("Show Plug-ins").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if hasHiddenTracks {
                        Toggle(isOn: $tlShowHiddenTracks) {
                            Text("Show Hidden").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if hasInactiveTracks {
                        Toggle(isOn: $tlShowInactiveTracks) {
                            Text("Show Inactive").font(.caption).foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
            }
            if visibleCount < totalCount {
                Text("Showing \(visibleCount) of \(totalCount) tracks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
            }
            // ── Track rows ─────────────────────────────────────────────────
            ForEach(visibleTracks, id: \.index) { track in
                TrackRow(track: track, showPlugins: showTrackPlugins,
                         showRouting: showRouting, showAtmos: hasAtmosData,
                         indentDepth: track.indentDepth)
            }
        }
    }

    // MARK: - Audio Files

    @ViewBuilder
    private var audioFilesContent: some View {
        if session.audioFileNames.isEmpty {
            PlaceholderRow(text: "No audio files found")
        } else {
            ForEach(Array(session.audioFileNames.enumerated()), id: \.offset) { _, name in
                AudioFileRow(name: name,
                             resolved: session.resolvedAudioFiles.first { $0.name == name })
            }
        }
    }

    // MARK: - Plugins

    @ViewBuilder
    private var pluginsContent: some View {
        if session.plugins.isEmpty {
            PlaceholderRow(text: "No plug-ins found")
        } else {
            if !pluginScanner.statusMessage.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).frame(width: 14)
                    Text(pluginScanner.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            HStack(spacing: 8) {
                Spacer()
                if !pluginScanner.scanCompleted && !pluginScanner.isScanning {
                    Button("Scan Plug-In Folder") { pluginScanner.scan() }
                    Text("(takes a moment)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button("Check Availability") { didCheckPlugins = true }
                    .disabled(!pluginScanner.scanCompleted || didCheckPlugins)
            }
            .font(.system(size: 11))
            .padding(.trailing, 8)
            .padding(.bottom, 4)
            ForEach(session.plugins, id: \.self) { plugin in
                PluginRow(plugin: plugin, installed: didCheckPlugins ? pluginScanner.index?.contains(
                    plugin, secondString: session.pluginSecondStrings[plugin]
                ) : nil)
            }
        }
    }

    // MARK: - Memory Locations

    @ViewBuilder
    private var memoryLocationsContent: some View {
        let sr       = Double(session.sampleRate) ?? 48000.0
        let fps      = session.frameRate
        let total    = totalSamples
        let filtered = markerSearch.isEmpty
            ? session.memoryLocations
            : session.memoryLocations.filter { $0.name.localizedCaseInsensitiveContains(markerSearch) }
        if session.memoryLocations.isEmpty {
            PlaceholderRow(text: "No memory locations")
        } else {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                TextField("Search", text: $markerSearch)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !markerSearch.isEmpty {
                    Button { markerSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
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
                                Text(formatTC(samples: loc.samplePosition, sr: sr, fps: fps))
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

// MARK: - Timecode formatting

func formatTC(samples: Int64, sr: Double, fps: Double) -> String {
    guard sr > 0, fps > 0, samples >= 0 else { return "—" }
    let totalFrames = Int64((Double(samples) / sr * fps).rounded())
    let fr  = Int64(fps.rounded())
    let f   = totalFrames % fr
    let sec = (totalFrames / fr) % 60
    let min = (totalFrames / fr / 60) % 60
    let hr  = totalFrames / fr / 3600
    return String(format: "%d:%02d:%02d:%02d", hr, min, sec, f)
}

func formatTC(_ seconds: Double, fps: Double) -> String {
    guard seconds.isFinite, seconds >= 0, fps > 0 else { return "0:00:00:00" }
    let totalFrames = Int((seconds * fps).rounded())
    let fr  = Int(fps.rounded())
    let f   = totalFrames % fr
    let sec = (totalFrames / fr) % 60
    let min = (totalFrames / fr / 60) % 60
    let hr  = totalFrames / fr / 3600
    return String(format: "%d:%02d:%02d:%02d", hr, min, sec, f)
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

// MARK: - Sticky section header (used inside LazyVStack pinnedViews)

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    var count: Int? = nil
    @Binding var isExpanded: Bool

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } } label: {
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
        .background(Color(nsColor: .windowBackgroundColor))
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
    let showPlugins: Bool
    var showRouting: Bool = false
    var showAtmos:   Bool = false
    var indentDepth: Int = 0

    // Indent absorbed inside the name zone so Format/Input/Output columns
    // stay at a fixed X position regardless of nesting.
    private static let indentWidth: CGFloat = 12
    private static let nameZoneWidth: CGFloat = 200   // matches column header

    var body: some View {
        let dimmed = track.isHidden || track.isInactive
        let totalIndent = CGFloat(indentDepth) * Self.indentWidth
        let nameWidth = Self.nameZoneWidth - totalIndent

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                // Indent spacer (zero width when not nested)
                Color.clear.frame(width: totalIndent)

                Image(systemName: track.type.systemImage)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : track.type.tintColor)
                    .frame(width: 16)

                HStack(spacing: 4) {
                    Text(track.name)
                        .font(.subheadline)
                        .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .italic(track.isInactive)
                        .lineLimit(1)
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
                .frame(width: nameWidth, alignment: .leading)
                .padding(.leading, 8)

                Text(track.channelFormat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 55, alignment: .center)

                if showRouting {
                    Text(track.inputPath ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .center)

                    Text(track.outputPath ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .center)
                }
                if showAtmos {
                    Group {
                        if track.isAtmosObject {
                            let label = track.atmosRendererInput > 0 ? "OBJ \(track.atmosRendererInput)" : "OBJ"
                            Text(label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.purple.opacity(0.4), lineWidth: 0.5))
                        } else if track.isAtmosBed {
                            let bedLabel: String = {
                                guard track.atmosRendererInput > 0 else { return "BED" }
                                let start = track.atmosRendererInput
                                let end   = start + max(track.channelCount, 1) - 1
                                return end > start ? "BED \(start)–\(end)" : "BED \(start)"
                            }()
                            Text(bedLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 65, alignment: .center)
                }
                Spacer(minLength: 0)
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
                // Align pills with track name (indent + icon + gap)
                .padding(.leading, totalIndent + 16 + 8)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
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
            if resolved == nil {
                Text("missing")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let url = resolved?.url {
                Text(url.pathExtension.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .contextMenu {
            if let url = resolved?.url {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                }
            }
        }
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


// MARK: - Plugin row (with optional availability badge)

private let elasticAudioModes: Set<String> = [
    "Polyphonic", "Rhythmic", "Monophonic", "Varispeed", "X-Form",
]

private struct PluginRow: View {
    let plugin:    String
    let installed: Bool?   // nil = not yet checked

    private var isElastic: Bool { elasticAudioModes.contains(plugin) }

    var body: some View {
        HStack(spacing: 8) {
            if isElastic {
                Image(systemName: "waveform.path")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(width: 16)
            } else if let ok = installed {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red)
                    .font(.system(size: 12))
                    .frame(width: 16)
            } else {
                Image(systemName: "puzzlepiece")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(plugin)
                .font(.subheadline)
            if isElastic {
                Text("Elastic Audio mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}

// MARK: - Overview resize handle

private struct OverviewResizeHandle: View {
    @Binding var height: CGFloat
    var maxHeight: CGFloat

    // Captures height at gesture start; auto-resets to nil when gesture ends.
    // Using @GestureState instead of a manual sentinel avoids coordinate-space
    // jitter that occurred when the handle's parent resized during the drag.
    @GestureState private var initialHeight: CGFloat? = nil

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
                .updating($initialHeight) { _, state, _ in
                    if state == nil { state = height }
                }
                .onChanged { val in
                    let base = initialHeight ?? height
                    height = max(50, min(maxHeight, base + val.translation.height))
                }
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

    // Global track height level (0 = base, each step doubles all lane heights, max 4)
    @Published var globalTrackHeightLevel: Int = 0
    // Per-track overrides on top of the global level
    @Published var trackHeightLevels: [Int: Int] = [:]

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

    // Saved view state for E zoom toggle (nil = not in zoom-toggle mode)
    private var zoomSnapshot: (scale: Double, viewStart: Double, trackHeightLevels: [Int: Int])? = nil

    private var keyMonitor:      Any?
    private var scrollMonitor:   Any?
    private var magnifyMonitor:  Any?

    var window: Double { 1.0 / scale }

    func startMonitoring() {
        guard keyMonitor == nil else { return }

        // Scroll wheel: horizontal = pan, Cmd+vertical = zoom
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isHovering || self.isFocused else { return event }
            guard !(event.window is NSPanel) else { return event }  // never consume panel/open-dialog events
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
                    let delta = -dx / 300.0 * self.window
                    self.viewStart = (self.viewStart + delta).clamped(to: 0...(1 - self.window))
                    return nil
                }
            }
            return event
        }

        // Trackpad pinch → horizontal zoom centred on cursor
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, self.isHovering || self.isFocused else { return event }
            guard !(event.window is NSPanel) else { return event }
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
            guard !(event.window is NSPanel) else { return event }
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
            case "e", "E": self.zoomToFitCursor(); return nil
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
            case "\u{f700}":   // Up arrow
                if mods.contains(.control) { self.adjustTrackHeight(by: +1); return nil }
                return event
            case "\u{f701}":   // Down arrow
                if mods.contains(.control) { self.adjustTrackHeight(by: -1); return nil }
                return event
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

    deinit { stopMonitoring() }

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
        centerOn(next)
    }

    func prevClipStart() {
        let idx = selTrack ?? 0
        guard !tracks.isEmpty else { return }
        let cursor = selStart ?? 1
        guard let prev = TimelineNav.prevClipStart(tracks: tracks, total: totalSamples,
                                                    trackIdx: idx, cursor: cursor,
                                                    hideMuted: hideMuted) else { return }
        selTrack = idx; selStart = prev; selEnd = nil
        centerOn(prev)
    }

    func nextClipEnd() {
        let idx = selTrack ?? 0
        guard !tracks.isEmpty else { return }
        let cursor = selStart ?? 0
        guard let next = TimelineNav.nextClipEnd(tracks: tracks, total: totalSamples,
                                                  trackIdx: idx, cursor: cursor,
                                                  hideMuted: hideMuted) else { return }
        selTrack = idx; selStart = next; selEnd = nil
        centerOn(next)
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
        centerOn(next)
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
        centerOn(prev)
    }

    // MARK: Per-track vertical zoom (Ctrl+Up / Ctrl+Down)

    func adjustGlobalTrackHeight(by delta: Int) {
        globalTrackHeightLevel = min(max(globalTrackHeightLevel + delta, 0), 4)
    }

    func adjustTrackHeight(by delta: Int) {
        guard let idx = selTrack else { return }
        let current = trackHeightLevels[idx, default: 0]
        trackHeightLevels[idx] = min(max(current + delta, 0), 4)
    }

    func resetTrackHeights() {
        trackHeightLevels.removeAll()
        globalTrackHeightLevel = 0
    }

    func jumpTo(_ frac: Double) {
        selStart = frac; selEnd = nil
        centerOn(frac)
    }

    func centerOn(_ frac: Double) {
        viewStart = (frac - window / 2).clamped(to: 0...(1 - window))
    }

    func ensureVisible(_ frac: Double) {
        let margin = window * 0.1
        if frac < viewStart + margin {
            viewStart = max(0, frac - margin)
        } else if frac > viewStart + window - margin {
            viewStart = min(1 - window, frac - window + margin)
        }
    }

    // E key (PT zoom toggle): first press saves view state and zooms to clip;
    // second press restores the saved state.
    func zoomToFitCursor() {
        // Second press — restore saved state
        if let snap = zoomSnapshot {
            scale             = snap.scale
            viewStart         = snap.viewStart
            trackHeightLevels = snap.trackHeightLevels
            zoomSnapshot      = nil
            return
        }

        // First press — need a cursor and a clip
        guard let s = selStart else { return }
        let savedState = (scale: scale, viewStart: viewStart, trackHeightLevels: trackHeightLevels)

        if let e = selEnd, e != s {
            zoomSnapshot = savedState
            zoomToSelection()
            return
        }

        guard let idx = selTrack, idx < tracks.count else { return }
        let samp = Int64((s * totalSamples).rounded())
        guard let clip = tracks[idx].clips.first(where: { $0.startSample == samp }) else { return }

        zoomSnapshot = savedState   // commit only once there's a clip to zoom to

        let clipStart = Double(clip.startSample) / totalSamples
        let clipEnd   = Double(clip.startSample + clip.lengthSamples) / totalSamples
        let span      = clipEnd - clipStart
        let margin    = max(span * 0.15, window * 0.05)
        let start     = max(0.0, clipStart - margin)
        let end       = min(1.0, clipEnd + margin)
        let newWin    = end - start
        scale         = max(1.0, 1.0 / newWin)
        viewStart     = start.clamped(to: 0...(1 - window))
        if trackHeightLevels[idx, default: 0] < 2 { trackHeightLevels[idx] = 2 }
    }
}

// MARK: - Universe-style timeline

private struct SessionTimelineView: View {
    @ObservedObject var tc: TimelineController
    @AppStorage("colorMode") private var colorMode: ColorMode = .dark

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
    @Binding var showEmpty:     Bool
    @Binding var overviewHeight: CGFloat

    // Hover state (view-owned for rendering; tc.hoverAbsFrac mirrors it for key handler)
    @State private var hoverAbsFrac:      Double?  = nil
    @State private var hoverLane:         Int?     = nil
    @State private var hoverClip:         PTXClip? = nil
    @State private var hoverClipTrackIdx: Int?     = nil

    // Drag/gesture state
    @State private var isDragging:  Bool   = false   // dragging a selection
    @State private var isPanning:   Bool   = false   // option+dragging to pan
    @State private var panOrigin:   (viewStart: Double, window: Double)? = nil

    // TC entry
    @State private var showTCEntry:  Bool   = false
    @State private var tcEntryText:  String = ""

    private static let audioLaneH: CGFloat = 8
    private static let videoLaneH: CGFloat = 16
    private static let laneGap:    CGFloat = 2
    private static let rulerH:     CGFloat = 30

    private static func trackLaneH(_ track: PTXTrack) -> CGFloat {
        track.type == .video ? videoLaneH : audioLaneH
    }
    private func scaledLaneH(_ track: PTXTrack, index: Int) -> CGFloat {
        let base  = Self.trackLaneH(track) * verticalScale
        let level = tc.globalTrackHeightLevel + tc.trackHeightLevels[index, default: 0]
        return base * CGFloat(1 << level)
    }
    private func trackColor(_ track: PTXTrack, index: Int) -> Color {
        ptTrackColor(track, index: index, grm: colorMode == .grm)
    }

    private func clipAt(trackIdx: Int?, sample: Int64, respectHideMuted: Bool = false) -> PTXClip? {
        guard let idx = trackIdx, idx < tracks.count else { return nil }
        return tracks[idx].clips.first {
            (!respectHideMuted || !$0.isMuted) &&
            sample >= $0.startSample &&
            sample < $0.startSample + $0.lengthSamples
        }
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

        // Derive selected clip from cursor position — no separate @State needed.
        // When tc.selStart changes (Published), body re-runs and this is already correct.
        let selectedClipSamp: Int64? = (tc.selEnd == nil) ? tc.selStart.map { Int64(($0 * total).rounded()) } : nil
        let selectedClip: PTXClip? = selectedClipSamp.flatMap { samp in
            guard let idx = tc.selTrack, idx < tracks.count else { return nil }
            return tracks[idx].clips.first { $0.startSample == samp }
        }
        let selectedClipTrackIdx: Int? = selectedClip != nil ? tc.selTrack : nil

        VStack(spacing: 0) {
            // ── Row 1: TC cursor | track label | zoom ────────────────────────
            HStack(spacing: 8) {
                // TC position / entry button — hover takes priority over cursor
                Button {
                    tcEntryText = tc.selStart.map { formatTC($0 * total / sr, fps: frameRate) } ?? ""
                    showTCEntry = true
                } label: {
                    Group {
                        if let absFrac = hoverAbsFrac {
                            Text(formatTC(absFrac * total / sr, fps: frameRate))
                                .foregroundStyle(.secondary)
                        } else if let s = tc.selStart {
                            if let e = tc.selEnd {
                                let lo  = min(s, e)
                                let dur = abs(e - s) * total / sr
                                Text("\(formatTC(lo * total / sr, fps: frameRate))  +\(formatTC(dur, fps: frameRate))")
                                    .foregroundStyle(.primary)
                            } else {
                                let samp = Int64((s * total).rounded())
                                Text("\(formatTC(s * total / sr, fps: frameRate))  (\(samp))")
                                    .foregroundStyle(.primary)
                            }
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

                // Track name — hover takes priority over selected track
                let displayIdx = hoverLane ?? tc.selTrack
                if let idx = displayIdx, idx < tracks.count {
                    let track = tracks[idx]
                    let color = trackColor(track, index: idx)
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

                // Track height (all lanes)
                HStack(spacing: 4) {
                    Text("V:").foregroundStyle(.secondary)
                    Button { tc.adjustGlobalTrackHeight(by: -1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).controlSize(.mini)
                        .disabled(tc.globalTrackHeightLevel == 0)
                    Button { tc.adjustGlobalTrackHeight(by: +1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).controlSize(.mini)
                        .disabled(tc.globalTrackHeightLevel == 4)
                }

                if !tc.trackHeightLevels.isEmpty || tc.globalTrackHeightLevel != 0 {
                    Divider().frame(height: 14)
                    Button { tc.resetTrackHeights() } label: {
                        Text("Reset Heights")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)

            // ── Row 2: selected clip (persistent — set by click) ─────────────
            clipInfoRow(
                clip: selectedClip, trackIdx: selectedClipTrackIdx,
                label: "SELECT", sr: sr, isSelected: true
            )

            // ── Row 3: hover clip (ephemeral — follows cursor) ────────────────
            clipInfoRow(
                clip: hoverClip, trackIdx: hoverClipTrackIdx,
                label: "HOVER", sr: sr, isSelected: false
            )

            // ── Checkbox row ─────────────────────────────────────────────────
            HStack(spacing: 12) {
                if hasMarkers {
                    Toggle(isOn: $showMarkers) {
                        Text("Show Markers").font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                }
                if hasVideo {
                    Toggle(isOn: $showVideo) {
                        Text("Show Video Track").font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                }
                if hasHidden {
                    Toggle(isOn: $showHidden) {
                        Text("Show Hidden Tracks").font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                }
                if hasInactive {
                    Toggle(isOn: $showInactive) {
                        Text("Show Inactive Tracks").font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                }
                Toggle(isOn: $showEmpty) {
                    Text("Show Empty Tracks").font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                if hasMuted {
                    Toggle(isOn: Binding(get: { !hideMuted }, set: { hideMuted = !$0 })) {
                        Text("Show Muted Clips").font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

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
                        Text(formatTC(tickSec, fps: fps))
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
                        // Short tick in the bottom strip only — keeps TC labels clean.
                        ctx.fill(Path(CGRect(x: x - 0.5, y: 18, width: 1, height: size.height - 18)),
                                 with: .color(.orange.opacity(0.7)))
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
                                    tc.isFocused = true
                                }
                        )
                }
            )

            // ── Scrollable lane area ──────────────────────────────────────────
            ScrollView(.vertical, showsIndicators: false) {
              ZStack(alignment: .topLeading) {
                // Clip canvas — Equatable so hover moves don't trigger a repaint.
                // Only redraws when tc publishes (pan/zoom/cursor) or selection changes.
                TimelineLaneCanvas(
                    viewStart:      tc.viewStart,
                    window:         tc.window,
                    selStart:       tc.selStart,
                    selEnd:         tc.selEnd,
                    selTrack:       tc.selTrack,
                    selTrackEnd:       tc.selTrackEnd,
                    trackHeightLevels: tc.trackHeightLevels,
                    tracks:                  tracks,
                    total:                   total,
                    hideMuted:               hideMuted,
                    verticalScale:           verticalScale,
                    grmMode:                 colorMode == .grm,
                    globalTrackHeightLevel:  tc.globalTrackHeightLevel
                )
                .equatable()

                // Hover hairline — cheap 0.5px canvas, redraws on every mouse move.
                HoverHairline(
                    hoverAbsFrac: hoverAbsFrac,
                    viewStart: tc.viewStart,
                    window: tc.window
                )
                .equatable()
                .allowsHitTesting(false)
              }
              .frame(height: totalLaneHeight)
              .overlay(
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .contextMenu {
                            if let laneIdx = hoverLane,
                               let absFrac = hoverAbsFrac {
                                let hovSample = Int64(absFrac * total)
                                if let clip = clipAt(trackIdx: laneIdx, sample: hovSample) {
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
                                if let idx = lane {
                                    let clip = clipAt(trackIdx: idx, sample: Int64(absFrac * total), respectHideMuted: hideMuted)
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

                                        let clickedClip = clipAt(trackIdx: clickLane,
                                                                     sample: Int64(frac * total),
                                                                     respectHideMuted: hideMuted)

                                        if let clip = clickedClip {
                                            // Place cursor at clip in-point; SEL row derives from this
                                            tc.selStart = Double(clip.startSample) / total
                                            tc.selEnd   = nil
                                        } else {
                                            // Empty space → cursor only, no clip selected
                                            tc.selStart = frac
                                            tc.selEnd   = nil
                                        }
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
            } // ScrollView
        }
        .onAppear {
            tc.tracks       = tracks
            tc.totalSamples = allTracksSamples > 0 ? allTracksSamples : visibleMax
            tc.hideMuted    = hideMuted
            tc.startMonitoring()
        }
        .onDisappear { tc.stopMonitoring() }
        .onChange(of: tracks)           { tc.tracks       = $0 }
        .onChange(of: allTracksSamples) { tc.totalSamples = $0 }
        .onChange(of: hideMuted)        { tc.hideMuted    = $0 }
        .onChange(of: tc.openTCEntry) { wants in
            guard wants else { return }
            tc.openTCEntry = false
            tcEntryText = tc.selStart.map { formatTC($0 * total / sr, fps: frameRate) } ?? ""
            showTCEntry = true
        }
    }

    private func clipInfoRow(clip: PTXClip?, trackIdx: Int?,
                             label: String, sr: Double, isSelected: Bool) -> some View {
        // Row always occupies 24px — no layout shift or flicker when clip changes.
        let color = trackIdx.map { t in
            t < tracks.count ? trackColor(tracks[t], index: t) : Color.secondary
        } ?? Color.secondary

        return HStack(spacing: 0) {
            // Label badge — fixed width so HOVER/SEL columns line up
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
                .frame(width: 52, alignment: .leading)

            if let clip, let tIdx = trackIdx {
                let inTC  = formatTC(Double(clip.startSample) / sr, fps: frameRate)
                let outTC = formatTC(Double(clip.startSample + clip.lengthSamples) / sr, fps: frameRate)
                let durTC = formatTC(Double(clip.lengthSamples) / sr, fps: frameRate)
                let trackName = tIdx < tracks.count ? tracks[tIdx].name : ""

                // Color swatch
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? color : color.opacity(0.5))
                    .frame(width: 3, height: 14)
                    .padding(.trailing, 6)

                // Track name
                if !trackName.isEmpty {
                    Text(trackName)
                        .foregroundStyle(isSelected ? color.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                        .frame(width: 100, alignment: .leading)
                        .padding(.trailing, 4)
                }

                // Clip name
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
                        .padding(.leading, 4)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .separatorColor).opacity(0.6)))
                }
                if clip.isGroup {
                    Text("clip group")
                        .font(.system(size: 9).weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .padding(.leading, 4)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .separatorColor).opacity(0.6)))
                }

                Spacer(minLength: 8)

                // In / Out / Length — plain text labels, fixed-width TC columns
                HStack(spacing: 0) {
                    Group {
                        Text("in ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        + Text(inTC).foregroundColor(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    }
                    .frame(width: 106, alignment: .trailing)

                    Group {
                        Text("  out ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        + Text(outTC).foregroundColor(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    }
                    .frame(width: 118, alignment: .trailing)

                    Group {
                        Text("  len ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        + Text(durTC).foregroundColor(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    }
                    .frame(width: 106, alignment: .trailing)
                }

            } else {
                Text("—").foregroundStyle(.tertiary).padding(.leading, 8)
                Spacer()
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(isSelected
            ? color.opacity(0.07)
            : Color(nsColor: .separatorColor).opacity(0.05))
    }


}

// MARK: - Timeline lane canvas (Equatable → skips repaint on hover-only state changes)

private struct TimelineLaneCanvas: View, Equatable {
    // All tc values that affect rendering passed as plain params so == can compare them.
    // No @ObservedObject — SessionTimelineView.body re-runs on tc changes and passes
    // updated values; == returns false → canvas redraws. Hover changes don't touch
    // these params → == returns true → canvas skipped.
    let viewStart:      Double
    let window:         Double
    let selStart:       Double?
    let selEnd:         Double?
    let selTrack:       Int?
    let selTrackEnd:       Int?
    let trackHeightLevels: [Int: Int]

    let tracks:               [PTXTrack]
    let total:                Double
    let hideMuted:            Bool
    let verticalScale:        CGFloat
    let grmMode:              Bool
    let globalTrackHeightLevel: Int

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewStart               == rhs.viewStart               &&
        lhs.window                  == rhs.window                  &&
        lhs.selStart                == rhs.selStart                &&
        lhs.selEnd                  == rhs.selEnd                  &&
        lhs.selTrack                == rhs.selTrack                &&
        lhs.selTrackEnd             == rhs.selTrackEnd             &&
        lhs.trackHeightLevels       == rhs.trackHeightLevels       &&
        lhs.tracks.count            == rhs.tracks.count            &&
        lhs.total                   == rhs.total                   &&
        lhs.hideMuted               == rhs.hideMuted               &&
        lhs.verticalScale           == rhs.verticalScale           &&
        lhs.grmMode                 == rhs.grmMode                 &&
        lhs.globalTrackHeightLevel  == rhs.globalTrackHeightLevel
    }

    private static let audioLaneH: CGFloat = 8
    private static let videoLaneH: CGFloat = 16
    private static let laneGap:    CGFloat = 2

    private func scaledLaneH(_ track: PTXTrack, index: Int) -> CGFloat {
        let base  = (track.type == .video ? Self.videoLaneH : Self.audioLaneH) * verticalScale
        let level = globalTrackHeightLevel + trackHeightLevels[index, default: 0]
        return base * CGFloat(1 << level)
    }

    private func trackColor(_ track: PTXTrack, index: Int) -> Color {
        ptTrackColor(track, index: index, grm: grmMode)
    }

    var body: some View {
        Canvas { ctx, size in
            let vStart  = viewStart
            let vWindow = window
            let availH  = size.height

            let selLo = min(selTrack ?? -1, selTrackEnd ?? selTrack ?? -1)
            let selHi = max(selTrack ?? -1, selTrackEnd ?? selTrack ?? -1)

            let winStartSamp = Int64((vStart * total).rounded(.down))
            let winEndSamp   = Int64(((vStart + vWindow) * total).rounded(.up))

            var laneY: CGFloat = 0
            for (i, track) in tracks.enumerated() {
                let thisLaneH  = scaledLaneH(track, index: i)
                let color      = trackColor(track, index: i)
                let isSelected = selLo >= 0 && i >= selLo && i <= selHi
                let bgAlpha: Double = isSelected ? 0.18 : 0.03

                ctx.fill(
                    Path(CGRect(x: 0, y: laneY, width: size.width, height: thisLaneH)),
                    with: .color(color.opacity(bgAlpha))
                )

                for clip in track.clips {
                    guard clip.lengthSamples > 0 else { continue }
                    if clip.startSample >= winEndSamp { break }
                    if clip.startSample + clip.lengthSamples <= winStartSamp { continue }
                    if hideMuted && clip.isMuted { continue }

                    let clipFracStart = Double(clip.startSample) / total
                    let clipFracLen   = Double(clip.lengthSamples) / total
                    let x = CGFloat((clipFracStart - vStart) / vWindow) * size.width
                    let w = max(1, CGFloat(clipFracLen / vWindow) * size.width)
                    let clipRect  = CGRect(x: x, y: laneY, width: w, height: thisLaneH)
                    let fillAlpha: Double = clip.isMuted ? 0.28 : 0.88
                    ctx.fill(Path(clipRect), with: .color(color.opacity(fillAlpha)))

                    if w >= 2 {
                        let edgeAlpha: Double = clip.isMuted ? 0.45 : 1.0
                        ctx.stroke(Path(clipRect), with: .color(color.opacity(edgeAlpha)),
                                   style: StrokeStyle(lineWidth: 1))
                        if w > 32 {
                            let fontSize: CGFloat = max(min(thisLaneH - 2, 10), 7)
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

            // Cursor / selection band (drawn over clips)
            if let sStart = selStart {
                let sx = CGFloat((sStart - vStart) / vWindow) * size.width
                if let sEnd = selEnd {
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
        }
    }
}

// MARK: - Hover hairline (Equatable → only redraws when hoverAbsFrac actually changes)

private struct HoverHairline: View, Equatable {
    var hoverAbsFrac: Double?
    var viewStart:    Double
    var window:       Double

    var body: some View {
        Canvas { ctx, size in
            guard let absFrac = hoverAbsFrac else { return }
            let hx = CGFloat((absFrac - viewStart) / window) * size.width
            if hx >= 0, hx <= size.width {
                ctx.fill(
                    Path(CGRect(x: hx, y: 0, width: 0.5, height: size.height)),
                    with: .color(.primary.opacity(0.35))
                )
            }
        }
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

// MARK: - Pro Tools color palette
//
// 69 colors: 23 columns × 3 rows, sampled directly from the PT Color Palette window.
// Row 0 (indices  0–22): vivid/bright
// Row 1 (indices 23–45): medium/dark
// Row 2 (indices 46–68): very dark
// colorIndex == -1 → no custom color; fall back to cycling palette.

let ptPalette: [Color] = [
    // Row 0 — vivid
    Color(hex: 0x2d32f2), Color(hex: 0x5035f2), Color(hex: 0x7d3af2),
    Color(hex: 0xb043f3), Color(hex: 0xae3aba), Color(hex: 0xad3485),
    Color(hex: 0xad2f54), Color(hex: 0xac2d1e), Color(hex: 0xad301e),
    Color(hex: 0xaf5825), Color(hex: 0xb58a32), Color(hex: 0xc0c442),
    Color(hex: 0x96c23f), Color(hex: 0x75c33d), Color(hex: 0x62c23c),
    Color(hex: 0x5dc23c), Color(hex: 0x5dc361), Color(hex: 0x5dc08c),
    Color(hex: 0x5dbfbf), Color(hex: 0x5ebef7), Color(hex: 0x4182f3),
    Color(hex: 0x2949f2), Color(hex: 0x1e31f2),
    // Row 1 — medium/dark
    Color(hex: 0x1e1d9c), Color(hex: 0x331e9c), Color(hex: 0x4e229c),
    Color(hex: 0x6b279d), Color(hex: 0x722583), Color(hex: 0x702063),
    Color(hex: 0x6f1c45), Color(hex: 0x6f1a13), Color(hex: 0x6f1d13),
    Color(hex: 0x713518), Color(hex: 0x74531e), Color(hex: 0x87802b),
    Color(hex: 0x6b7f28), Color(hex: 0x557e27), Color(hex: 0x457d26),
    Color(hex: 0x3c7d26), Color(hex: 0x3b7d3c), Color(hex: 0x3b7d54),
    Color(hex: 0x42897d), Color(hex: 0x448aa0), Color(hex: 0x33679f),
    Color(hex: 0x23459d), Color(hex: 0x17229c),
    // Row 2 — very dark
    Color(hex: 0x130d5b), Color(hex: 0x1e0e5b), Color(hex: 0x2d105b),
    Color(hex: 0x3b135b), Color(hex: 0x441354), Color(hex: 0x410f3f),
    Color(hex: 0x400e30), Color(hex: 0x400b0e), Color(hex: 0x41110e),
    Color(hex: 0x411f10), Color(hex: 0x432d13), Color(hex: 0x554d1b),
    Color(hex: 0x434918), Color(hex: 0x374918), Color(hex: 0x2c4917),
    Color(hex: 0x254a17), Color(hex: 0x224922), Color(hex: 0x22492f),
    Color(hex: 0x2a584c), Color(hex: 0x2b575d), Color(hex: 0x23455c),
    Color(hex: 0x1c335c), Color(hex: 0x15225b),
]

// Okabe-Ito colorblind-safe palette (used in GRM mode)
let grmPalette: [Color] = [
    Color(hex: 0x0072B2),  // blue
    Color(hex: 0xE69F00),  // orange
    Color(hex: 0x009E73),  // bluish green
    Color(hex: 0xCC79A7),  // reddish purple
    Color(hex: 0x56B4E9),  // sky blue
    Color(hex: 0xD55E00),  // vermilion
    Color(hex: 0xF0E442),  // yellow
]

func ptTrackColor(_ track: PTXTrack, index: Int, grm: Bool = false) -> Color {
    if track.type == .video { return Color(white: 0.52) }
    if grm { return grmPalette[index % grmPalette.count] }
    let idx = track.colorIndex
    // Binary color indices start at 25 (0x19) — palette slot 0 is index 25.
    let slot = idx - 25
    if slot >= 0, slot < ptPalette.count { return ptPalette[slot] }
    // Fallback: cycle through a fixed palette by track index
    let fallback: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo, .yellow, .red, .teal, .brown]
    return fallback[index % fallback.count]
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >>  8) & 0xff) / 255
        let b = Double( hex        & 0xff) / 255
        self.init(red: r, green: g, blue: b)
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

    var filterLabel: String {
        switch self {
        case .audio:      return "Audio"
        case .midi:       return "MIDI"
        case .aux:        return "Aux"
        case .master:     return "Master"
        case .vca:        return "VCA"
        case .video:      return "Video"
        case .folder:     return "Folder"
        case .instrument: return "Inst"
        case .unknown:    return "Other"
        }
    }
}
