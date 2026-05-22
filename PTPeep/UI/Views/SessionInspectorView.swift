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
    var isResolvingFiles: Bool = false
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
    @State private var trackSectionExpanded:   Bool = false
    @State private var audioSectionExpanded:   Bool = false
    @State private var pluginSectionExpanded:  Bool = false
    @State private var showPluginOptions:      Bool = false
    @State private var memLocSectionExpanded:  Bool = false
    @State private var overviewHeight:   CGFloat = 0     // 0 = auto-init on first render
    @State private var availableHeight:  CGFloat = 500   // updated by GeometryReader in body
    @State private var showTrackPlugins: Bool = false
    @State private var showTrackSends:   Bool = false
    @State private var showTrackOptions: Bool = false
    @State private var trackSortColumn: TrackSortColumn = .none
    @State private var trackSortAscending: Bool = true

    private enum TrackSortColumn { case none, name, format, input, output, atmos }
    @ObservedObject private var pluginScanner = PluginScanner.shared
    @StateObject private var tc = TimelineController()
    @StateObject private var audioPlayer = AudioPlayer()

    private var hasRoutingData: Bool {
        session.tracks.contains { $0.inputPath != nil || $0.outputPath != nil }
    }
    private var hasSendsData: Bool {
        session.tracks.contains { !$0.sendPaths.isEmpty }
    }
    private var hasPlugins: Bool {
        session.tracks.contains { !$0.plugins.isEmpty }
    }
    private var hasHiddenTracks: Bool   { session.tracks.contains { $0.isHidden } }
    private var hasInactiveTracks: Bool { session.tracks.contains { $0.isInactive } }

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
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // ── Tracks ───────────────────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            if trackSectionExpanded { tracksContent }
                            Divider().padding(.horizontal, 16)
                        }
                    } header: {
                        VStack(spacing: 0) {
                            tracksHeader
                            if trackSectionExpanded { trackColumnHeader }
                        }
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                    // ── Audio Files ───────────────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            if audioSectionExpanded {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    audioFilesContent
                                }
                            }
                            Divider().padding(.horizontal, 16)
                        }
                    } header: {
                        SectionHeader(title: "Audio Files", systemImage: "waveform",
                                      count: session.audioFileNames.count,
                                      isLoading: isResolvingFiles,
                                      isExpanded: $audioSectionExpanded)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                    // ── Plug-Ins ──────────────────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            if pluginSectionExpanded { pluginsContent }
                            Divider().padding(.horizontal, 16)
                        }
                    } header: {
                        pluginsHeader
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

    /// Compact session-setup subtitle: "24-bit · 48kHz · 23.976 · 00:58:00:00"
    private var sessionSetupSubtitle: String {
        var parts: [String] = []
        if !session.bitDepth.isEmpty   { parts.append("\(session.bitDepth)-bit") }
        if !session.sampleRate.isEmpty { parts.append("\(session.sampleRate)Hz") }
        if !session.tcFormat.isEmpty   { parts.append(session.tcFormat) }
        if !session.sessionStart.isEmpty { parts.append(session.sessionStart) }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.sessionName)
                        .font(.headline)
                    let sub = sessionSetupSubtitle
                    if !sub.isEmpty {
                        Text("(\(sub))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
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
        // Leave ~180 px for the collapsible sections below the overview.
        let maxH = max(100, availableHeight - 180)
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
                    // Scale by current global track height level
                    let scaledLanesH = baseLanesH * CGFloat(1 << tc.globalTrackHeightLevel)
                    // overhead = hover+toolbar row(24) + sel row(24) + transport(22) + waveform(64) + ruler(30) + padding(4)
                    let overhead: CGFloat = 168
                    // Auto-init height on first render: fit all tracks at current zoom, capped at 500
                    let effectiveH: CGFloat = {
                        if overviewHeight == 0 {
                            let h = min(scaledLanesH + overhead, 500)
                            DispatchQueue.main.async { overviewHeight = h }
                            return h
                        }
                        return overviewHeight
                    }()
                    // Extend one hour past the last clip. Do NOT use PTSL session length —
                    // PT may have a different session open than the file we're inspecting.
                    let clipMax = clippedTracks.flatMap(\.clips)
                        .map { $0.startSample + $0.lengthSamples }.max() ?? 0
                    let visibleMax = Double(max(clipMax, 1)) + sr * 3600
                    SessionTimelineView(tc: tc,
                                        tracks: clippedTracks,
                                        allTracksSamples: visibleMax,
                                        sampleRate: sr,
                                        frameRate: session.frameRate,
                                        tcFormat:  session.tcFormat,
                                        verticalScale: 1.0,
                                        resolvedFiles: session.resolvedAudioFiles,
                                        audioPlayer: audioPlayer,
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

    // MARK: - Tracks header (custom — includes pane options menu)

    private var tracksHeader: some View {
        HStack(spacing: 0) {
            // Left: tap to expand/collapse
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { trackSectionExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Tracks")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("(\(session.tracks.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Right: pane options + chevron
            let optionsActive = !hiddenTrackTypes.isEmpty || showTrackSends || showTrackPlugins
                             || tlShowHiddenTracks || !tlShowInactiveTracks
            Button { showTrackOptions.toggle() } label: {
                Image(systemName: optionsActive ? "ellipsis.circle.fill" : "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(optionsActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .popover(isPresented: $showTrackOptions, arrowEdge: .bottom) {
                trackOptionsPopover
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { trackSectionExpanded.toggle() }
            } label: {
                Image(systemName: trackSectionExpanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .separatorColor).opacity(0.1))
    }

    @ViewBuilder private var trackOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Visibility")
                .font(.system(size: 10).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            if hasHiddenTracks   { Toggle("Show Hidden Tracks",   isOn: $tlShowHiddenTracks).toggleStyle(.checkbox) }
            if hasInactiveTracks { Toggle("Show Inactive Tracks", isOn: $tlShowInactiveTracks).toggleStyle(.checkbox) }
            ForEach(presentTrackTypes, id: \.self) { type in
                Toggle(isOn: Binding(
                    get: { !hiddenTrackTypes.contains(type) },
                    set: { show in
                        if show { hiddenTrackTypes.remove(type) }
                        else    { hiddenTrackTypes.insert(type) }
                    }
                )) {
                    Label(type.filterLabel, systemImage: type.systemImage)
                }
                .toggleStyle(.checkbox)
            }
            if hasSendsData  { Toggle("Sends",    isOn: $showTrackSends).toggleStyle(.checkbox) }
            if hasPlugins    { Toggle("Plug-ins", isOn: $showTrackPlugins).toggleStyle(.checkbox) }
            if !hiddenTrackTypes.isEmpty {
                Button("Show All") { hiddenTrackTypes.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(minWidth: 180)
    }

    private var presentTrackTypes: [PTXTrackType] {
        let order: [PTXTrackType] = [.audio, .instrument, .midi, .aux, .vca, .master, .folder, .video, .unknown]
        return order.filter { t in session.tracks.contains { $0.type == t } }
    }

    private var hasAtmosData: Bool {
        session.tracks.contains { $0.isAtmosObject || $0.isAtmosBed }
    }

    private var trackColumnHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 24)  // icon (16) + gap (8)
            sortableColumnHeader("Name",   col: .name,   width: 200, alignment: .leading)
            sortableColumnHeader("Format", col: .format, width: 55)
            if hasRoutingData {
                sortableColumnHeader("Input",  col: .input,  width: 110)
                sortableColumnHeader("Output", col: .output, width: 110)
            }
            if hasAtmosData {
                sortableColumnHeader("Atmos",  col: .atmos,  width: 65)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sortableColumnHeader(_ title: String, col: TrackSortColumn,
                                      width: CGFloat, alignment: Alignment = .center) -> some View {
        Button {
            if col == .none { return }
            if trackSortColumn == col { trackSortAscending.toggle() }
            else { trackSortColumn = col; trackSortAscending = true }
        } label: {
            HStack(spacing: 2) {
                if alignment == .leading {
                    Text(title).font(.caption2)
                    if trackSortColumn == col {
                        Image(systemName: trackSortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Text(title).font(.caption2)
                    if trackSortColumn == col {
                        Image(systemName: trackSortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(trackSortColumn == col ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tracksContent: some View {
        let filtered = session.tracks.filter {
            !hiddenTrackTypes.contains($0.type)
            && (tlShowHiddenTracks   || !$0.isHidden)
            && (tlShowInactiveTracks || !$0.isInactive)
        }
        let visibleTracks: [PTXTrack] = {
            let asc = trackSortAscending
            switch trackSortColumn {
            case .none:
                return filtered
            case .name:
                return filtered.sorted {
                    let c = $0.name.localizedCaseInsensitiveCompare($1.name)
                    return c == .orderedSame ? $0.index < $1.index : asc ? c == .orderedAscending : c == .orderedDescending
                }
            case .format:
                return filtered.sorted {
                    let c = $0.channelFormat.localizedCaseInsensitiveCompare($1.channelFormat)
                    return c == .orderedSame ? $0.index < $1.index : asc ? c == .orderedAscending : c == .orderedDescending
                }
            case .input:
                return filtered.sorted {
                    let a = $0.inputPath ?? "", b = $1.inputPath ?? ""
                    let c = a.localizedCaseInsensitiveCompare(b)
                    return c == .orderedSame ? $0.index < $1.index : asc ? c == .orderedAscending : c == .orderedDescending
                }
            case .output:
                return filtered.sorted {
                    let a = $0.outputPath ?? "", b = $1.outputPath ?? ""
                    let c = a.localizedCaseInsensitiveCompare(b)
                    return c == .orderedSame ? $0.index < $1.index : asc ? c == .orderedAscending : c == .orderedDescending
                }
            case .atmos:
                return filtered.sorted {
                    let a = $0.atmosRendererInput == 0 ? Int.max : $0.atmosRendererInput
                    let b = $1.atmosRendererInput == 0 ? Int.max : $1.atmosRendererInput
                    return a == b ? $0.index < $1.index : asc ? a < b : a > b
                }
            }
        }()
        let totalCount   = session.tracks.count
        let visibleCount = visibleTracks.count
        if session.tracks.isEmpty {
            PlaceholderRow(text: "No tracks found")
        } else {
            if visibleCount < totalCount || trackSortColumn != .none {
                HStack(spacing: 8) {
                    if visibleCount < totalCount {
                        Text("Showing \(visibleCount) of \(totalCount) tracks")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if trackSortColumn != .none {
                        Button("Session Order") {
                            trackSortColumn = .none
                            trackSortAscending = true
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
            // ── Track rows ─────────────────────────────────────────────────
            ForEach(visibleTracks, id: \.index) { track in
                TrackRow(track: track, showPlugins: showTrackPlugins,
                         pluginInstalled: { name in
                             guard pluginScanner.scanCompleted else { return nil }
                             return pluginScanner.index?.contains(name, secondString: session.pluginSecondStrings[name])
                         },
                         showRouting: hasRoutingData, showSends: showTrackSends,
                         showAtmos: hasAtmosData, indentDepth: track.indentDepth)
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

    private var pluginsHeader: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { pluginSectionExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Plug-Ins Used")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("(\(session.plugins.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { showPluginOptions.toggle() } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .popover(isPresented: $showPluginOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        pluginScanner.scan()
                        showPluginOptions = false
                    } label: {
                        Label("Rescan Plug-ins Folder", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(pluginScanner.isScanning)
                }
                .font(.system(size: 12))
                .padding(12)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { pluginSectionExpanded.toggle() }
            } label: {
                Image(systemName: pluginSectionExpanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .separatorColor).opacity(0.1))
    }

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
            if !pluginScanner.scanCompleted && !pluginScanner.isScanning {
                HStack(spacing: 8) {
                    Text("Scan your plug-in folder to check which plug-ins are installed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan") { pluginScanner.scan() }
                    Text("(takes a moment)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            ForEach(session.plugins, id: \.self) { plugin in
                PluginRow(plugin: plugin, installed: pluginScanner.scanCompleted ? pluginScanner.index?.contains(
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
    var isLoading: Bool = false
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
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else if let n = count {
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

private struct TrackRow: View {
    let track: PTXTrack
    let showPlugins: Bool
    var pluginInstalled: (String) -> Bool? = { _ in nil }
    var showRouting: Bool = false
    var showSends:   Bool = false
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

                Text({
                    if track.isAtmosBed, track.atmosBedChannelCount > 0 {
                        switch track.atmosBedChannelCount {
                        case 1:  return "Mono"
                        case 2:  return "Stereo"
                        case 3:  return "LCR"
                        case 4:  return "Quad"
                        case 5:  return "5.0"
                        case 6:  return "5.1"
                        case 7:  return "6.1"
                        case 8:  return "7.1"
                        case 9:  return "7.0.2"
                        case 10: return "7.1.2"
                        case 11: return "7.0.4"
                        case 12: return "7.1.4"
                        default: return "\(track.atmosBedChannelCount)ch"
                        }
                    }
                    return track.channelFormat
                }())
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
                            let label: String = {
                                guard track.atmosRendererInput > 0 else { return "OBJ" }
                                if track.channelCount >= 2 {
                                    return "OBJ \(track.atmosRendererInput)|\(track.atmosRendererInput + 1)"
                                }
                                return "OBJ \(track.atmosRendererInput)"
                            }()
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
                                guard track.atmosBedChannelCount > 1 else { return "BED \(start)" }
                                let end = start + track.atmosBedChannelCount - 1
                                return "BED \(start)–\(end)"
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

            // Send pills
            if showSends && !track.sendPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        ForEach(track.sendPaths, id: \.self) { send in
                            Text(send)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.teal.opacity(0.12))
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(Color.teal.opacity(0.3), lineWidth: 0.5))
                        }
                    }
                }
                .padding(.leading, totalIndent + 16 + 8)
            }

            // Plugin pills
            if showPlugins && !track.plugins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(track.plugins, id: \.self) { plugin in
                            let ok = pluginInstalled(plugin)
                            let fg: AnyShapeStyle = ok == nil ? AnyShapeStyle(.secondary)
                                : ok! ? AnyShapeStyle(Color.green)  : AnyShapeStyle(Color.red)
                            let bg: Color = ok == nil ? Color(nsColor: .separatorColor).opacity(0.4)
                                : ok! ? Color.green.opacity(0.12)   : Color.red.opacity(0.12)
                            let border: Color = ok == nil ? .clear
                                : ok! ? Color.green.opacity(0.4)    : Color.red.opacity(0.4)
                            Text(plugin)
                                .font(.system(size: 9))
                                .foregroundStyle(fg)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(bg)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
                        }
                    }
                }
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
    @Published var globalTrackHeightLevel: Int = 2
    // Per-track overrides on top of the global level
    @Published var trackHeightLevels: [Int: Int] = [:]

    // Interaction context (not published — used by key handler only)
    var isHovering:   Bool    = false
    var isFocused:    Bool    = false
    var hoverAbsFrac: Double? = nil

    // Signal to view to open the TC entry popover (numpad *)
    @Published var openTCEntry: Bool = false
    // Signal to view to toggle playback (spacebar)
    @Published var spacebarTapped: Int = 0

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
            case " ":      self.spacebarTapped += 1;      return nil  // Spacebar → play/stop
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
    var audioPlayer: AudioPlayer? = nil
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

    // Waveform channel URLs — cached so multiMonoChannels isn't called on every 60fps render
    @State private var waveChannelURLs: [URL] = []

    // TC entry
    @State private var showTCEntry:      Bool   = false
    @State private var tcEntryText:      String = ""
    @State private var showFiltersPopover: Bool  = false
    @AppStorage("ov.autoplay") private var autoplay: Bool = false

    // BWF metadata panel
    @AppStorage("bwf.panelVisible")     private var bwfPanelVisible: Bool   = false
    @AppStorage("bwf.selectedFields")   private var bwfFieldsRaw:    String = BWFFieldKey.defaults.map(\.rawValue).joined(separator: ",")
    @State private var bwfMetadata:     BWFMetadata? = nil
    @State private var showBWFSettings: Bool         = false

    private var bwfSelectedFields: [BWFFieldKey] {
        bwfFieldsRaw.split(separator: ",").compactMap { BWFFieldKey(rawValue: String($0)) }
    }
    private func bwfToggleField(_ key: BWFFieldKey) {
        var current = bwfSelectedFields
        if let idx = current.firstIndex(of: key) {
            current.remove(at: idx)
        } else {
            current.append(key)
        }
        bwfFieldsRaw = current.map(\.rawValue).joined(separator: ",")
    }

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

    /// Applies a shift-click to extend the current selection to include the clicked clip/position.
    private func applyShiftClick(clickedClip: PTXClip?, clickFrac: Double, clickLane: Int?, total: Double) {
        guard let existing = tc.selStart else { return }
        let anchor = tc.selEnd == nil ? existing : min(existing, tc.selEnd!)
        let targetStart: Double
        let targetEnd: Double
        if let clip = clickedClip {
            targetStart = Double(clip.startSample) / total
            let clipEndSamp = clip.startSample + clip.lengthSamples
            targetEnd = Double(clipEndSamp) / total
        } else {
            targetStart = clickFrac
            targetEnd   = clickFrac
        }
        let newStart = min(anchor, targetStart)
        let newEnd   = max(tc.selEnd ?? existing, existing, targetEnd)
        tc.selStart    = newStart
        tc.selEnd      = newEnd > newStart ? newEnd : nil
        if let lane = clickLane {
            let loTrack    = min(tc.selTrack ?? lane, lane)
            let hiTrack    = max(tc.selTrackEnd ?? tc.selTrack ?? lane, lane)
            tc.selTrack    = loTrack
            tc.selTrackEnd = hiTrack != loTrack ? hiTrack : nil
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

    /// Tightens tc.selStart / tc.selEnd to the actual earliest/latest clip edges
    /// within the current selection, removing any leading/trailing silence.
    private func snapSelectionToClipBounds(total: Double) {
        guard let s = tc.selStart, let e = tc.selEnd, e > s else { return }
        let startSamp = Int64((s * total).rounded())
        let endSamp   = Int64((e * total).rounded())
        let trackLo   = min(tc.selTrack ?? 0, tc.selTrackEnd ?? (tc.selTrack ?? 0))
        let trackHi   = max(tc.selTrack ?? 0, tc.selTrackEnd ?? (tc.selTrack ?? 0))
        let hiIdx     = min(trackHi, tracks.count - 1)
        guard trackLo >= 0, trackLo <= hiIdx else { return }

        var minStart = endSamp
        var maxEnd   = startSamp
        for idx in trackLo...hiIdx {
            let track = tracks[idx]
            guard track.type == .audio else { continue }
            for clip in track.clips {
                guard !clip.isGroup,
                      clip.startSample < endSamp,
                      clip.startSample + clip.lengthSamples > startSamp else { continue }
                minStart = min(minStart, clip.startSample)
                maxEnd   = max(maxEnd, clip.startSample + clip.lengthSamples)
            }
        }
        guard minStart < maxEnd else { return }
        let croppedStart = max(startSamp, minStart)
        let croppedEnd   = min(endSamp, maxEnd)
        if croppedStart != startSamp { tc.selStart = Double(croppedStart) / total }
        if croppedEnd   != endSamp   { tc.selEnd   = Double(croppedEnd)   / total }
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

        // Build a PlayRegion when the user has drawn a time selection (selEnd != nil),
        // or when the cursor is on a group clip (isGroup == true).
        // Group clips expand by position: all non-group clips across all tracks that
        // fall within the group's time range are treated as the group's contents.
        let selectedRegion: PlayRegion? = {
            let startSamp: Int64
            let endSamp:   Int64
            let trackLo:   Int
            let trackHi:   Int

            if let clip = selectedClip, clip.isGroup {
                // Group clip: expand across all tracks over the group's duration
                startSamp = clip.startSample
                endSamp   = clip.startSample + clip.lengthSamples
                trackLo   = 0
                trackHi   = tracks.count - 1
            } else if let s = tc.selStart, let e = tc.selEnd, e > s {
                // User-drawn time selection
                startSamp = Int64((s * total).rounded())
                endSamp   = Int64((e * total).rounded())
                trackLo   = tc.selTrack ?? 0
                trackHi   = tc.selTrackEnd ?? trackLo
            } else {
                return nil
            }

            guard endSamp > startSamp else { return nil }

            // Safety cap: don't build a region that would require reading
            // hundreds of files or gigabytes of audio on the main thread.
            let kMaxClips: Int    = 25
            let kMaxSec:   Double = 120.0
            let durationSec = Double(endSamp - startSamp) / sr
            guard durationSec <= kMaxSec else { return nil }

            let hiIdx = min(max(trackLo, trackHi), tracks.count - 1)
            guard trackLo >= 0, trackLo <= hiIdx else { return nil }

            var segments: [PlayRegion.TrackSegment] = []
            var totalClips = 0
            for idx in trackLo...hiIdx {
                let track = tracks[idx]
                guard track.type == .audio else { continue }
                let clipsInRange = track.clips.filter { clip in
                    !clip.isGroup &&
                    !clip.isMuted &&   // muted clips never play in a region
                    clip.startSample < endSamp &&
                    clip.startSample + clip.lengthSamples > startSamp
                }.sorted { $0.startSample < $1.startSample }

                let resolved = clipsInRange.compactMap { clip -> (PTXClip, URL)? in
                    guard let url = resolvedFiles.first(where: { $0.name == clip.sourceFile })?.url
                    else { return nil }
                    return (clip, url)
                }
                if !resolved.isEmpty {
                    totalClips += resolved.count
                    segments.append(PlayRegion.TrackSegment(trackIdx: idx, clips: resolved))
                }
                if totalClips > kMaxClips { return nil }  // bail early
            }
            guard !segments.isEmpty else { return nil }

            // Crop to actual clip bounds — drop leading/trailing silence from the selection.
            let allClips = segments.flatMap(\.clips).map(\.clip)
            let croppedStart = allClips.map(\.startSample).min() ?? startSamp
            let croppedEnd   = allClips.map { $0.startSample + $0.lengthSamples }.max() ?? endSamp

            return PlayRegion(startSample: max(startSamp, croppedStart),
                              endSample:   min(endSamp,   croppedEnd),
                              segments: segments, sampleRate: sr,
                              resolvedPool: resolvedFiles.compactMap(\.url))
        }()

        VStack(spacing: 0) {
            // ── HOVER row + zoom/filter controls (single row) ───────────────
            HStack(spacing: 0) {
                // Hover clip info (left side — no in/out/length)
                hoverInfoRow(clip: hoverClip, trackIdx: hoverClipTrackIdx,
                             sr: sr, total: total,
                             resolvedURL: resolvedFiles.first(where: { $0.name == hoverClip?.sourceFile })?.url,
                             cursorAbsFrac: hoverClip == nil ? hoverAbsFrac : nil,
                             cursorLane:    hoverClip == nil ? hoverLane    : nil)
                    .onTapGesture {
                        tcEntryText = tc.selStart.map { formatTC($0 * total / sr, fps: frameRate) } ?? ""
                        showTCEntry = true
                    }

                Spacer(minLength: 8)

                // Zoom controls (right side)
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

                Divider().frame(height: 14).padding(.horizontal, 6)

                HStack(spacing: 4) {
                    Text("V:").foregroundStyle(.secondary)
                    Button { tc.adjustGlobalTrackHeight(by: -1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).controlSize(.mini)
                        .disabled(tc.globalTrackHeightLevel == 0)
                    Button { tc.adjustGlobalTrackHeight(by: +1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).controlSize(.mini)
                        .disabled(tc.globalTrackHeightLevel == 4)
                }

                Divider().frame(height: 14).padding(.horizontal, 6)

                let filtersActive = autoplay || showHidden || showInactive || !showVideo || hideMuted || showMarkers || !showEmpty
                Button { showFiltersPopover.toggle() } label: {
                    Image(systemName: filtersActive ? "ellipsis.circle.fill" : "ellipsis.circle")
                        .foregroundStyle(filtersActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Pane options")
                .popover(isPresented: $showFiltersPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Playback")
                            .font(.system(size: 10).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                        Toggle("Auto-play on click", isOn: $autoplay).toggleStyle(.checkbox)
                        Divider()
                        Text("Visibility")
                            .font(.system(size: 10).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                        if hasMarkers   { Toggle("Show Markers",         isOn: $showMarkers).toggleStyle(.checkbox) }
                        if hasVideo     { Toggle("Show Video Track",     isOn: $showVideo).toggleStyle(.checkbox) }
                        if hasHidden    { Toggle("Show Hidden Tracks",   isOn: $showHidden).toggleStyle(.checkbox) }
                        if hasInactive  { Toggle("Show Inactive Tracks", isOn: $showInactive).toggleStyle(.checkbox) }
                                          Toggle("Show Empty Tracks",    isOn: $showEmpty).toggleStyle(.checkbox)
                        if hasMuted {
                            Toggle("Show Muted Clips",
                                   isOn: Binding(get: { !hideMuted }, set: { hideMuted = !$0 }))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .font(.system(size: 12))
                    .padding(12)
                    .frame(minWidth: 180)
                }

                if !tc.trackHeightLevels.isEmpty || tc.globalTrackHeightLevel != 2 {
                    Divider().frame(height: 14).padding(.horizontal, 6)
                    Button { tc.resetTrackHeights() } label: { Text("Reset") }
                        .buttonStyle(.borderless)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 0)
            .padding(.trailing, 8)
            .frame(height: 24)

            // ── SELECT clip row ───────────────────────────────────────────────
            clipInfoRow(clip: selectedClip, trackIdx: selectedClipTrackIdx,
                        label: "SELECT", sr: sr, total: total, isSelected: true,
                        resolvedURL: resolvedFiles.first(where: { $0.name == selectedClip?.sourceFile })?.url)

            // ── Transport strip ───────────────────────────────────────────────
            HStack(spacing: 8) {
                // Play / stop or offline indicator
                if let clip = selectedClip, !clip.isGroup {
                    let resolvedURL = resolvedFiles.first(where: { $0.name == clip.sourceFile })?.url
                    if let ap = audioPlayer, let url = resolvedURL {
                        let playing = ap.isPlaying && ap.playingClip == clip
                        let selColor = selectedClipTrackIdx.map { t in
                            t < tracks.count ? trackColor(tracks[t], index: t) : Color.secondary
                        } ?? Color.secondary
                        Button {
                            playing ? ap.stop() : ap.play(clip: clip, url: url, sampleRate: sr)
                        } label: {
                            Image(systemName: playing ? "stop.fill" : "play.fill")
                                .foregroundStyle(playing ? Color.red : selColor)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                    } else if !clip.sourceFile.isEmpty {
                        // File could not be resolved on disk
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("Offline")
                            .font(.system(size: 10).weight(.medium))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.clear)
                    }
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.clear)
                }

                // Source file name when a clip is selected
                if let clip = selectedClip, !clip.sourceFile.isEmpty {
                    Divider().frame(height: 12)
                    Text(clip.sourceFile)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // TC counter — always visible; priority: playback > cursor > hover > dash
                Group {
                    if let ap = audioPlayer, ap.isPlaying, let clip = ap.playingClip {
                        let samp = Double(clip.startSample) + ap.playbackFraction * Double(clip.lengthSamples)
                        Text(formatTC(samp / sr, fps: frameRate))
                            .foregroundStyle(Color(nsColor: .labelColor))
                    } else if let frac = tc.selStart {
                        Text(formatTC(frac * total / sr, fps: frameRate))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    } else if let frac = hoverAbsFrac {
                        Text(formatTC(frac * total / sr, fps: frameRate))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    } else {
                        Text("—")
                            .foregroundStyle(.quaternary)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor).opacity(0.4)))
                .onTapGesture {
                    tcEntryText = tc.selStart.map { formatTC($0 * total / sr, fps: frameRate) } ?? ""
                    showTCEntry = true
                }
                .popover(isPresented: $showTCEntry, arrowEdge: .top) {
                    TCEntryPopover(text: $tcEntryText) { text in
                        if let frac = TimelineNav.parseTCFrac(text, fps: frameRate,
                                                              totalSamples: total, sampleRate: sr) {
                            tc.jumpTo(frac)
                        }
                        showTCEntry = false
                    }
                }
                .help("Click to jump to timecode")

                Divider().frame(height: 12).padding(.horizontal, 4)

                // Volume fader
                if let ap = audioPlayer {
                    VolumeFaderView(volume: Binding(get: { ap.volume }, set: { ap.volume = $0 }))
                        .frame(width: 72)
                }

                // Spot to PT
                spotButton(region: selectedRegion, clip: selectedClip,
                           resolvedFiles: resolvedFiles)

                Divider().frame(height: 12)

                // BWF toggle + settings
                Button {
                    bwfPanelVisible.toggle()
                    if bwfPanelVisible, let clip = selectedClip,
                       let url = resolvedFiles.first(where: { $0.name == clip.sourceFile })?.url {
                        Task.detached(priority: .userInitiated) {
                            let m = BWFParser.parse(url: url)
                            await MainActor.run { bwfMetadata = m }
                        }
                    } else if !bwfPanelVisible {
                        bwfMetadata = nil
                    }
                } label: {
                    Text("BWF")
                        .font(.system(size: 9).weight(.semibold))
                        .foregroundStyle(bwfPanelVisible ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(bwfPanelVisible
                                  ? Color.accentColor.opacity(0.15)
                                  : Color(nsColor: .separatorColor).opacity(0.5)))
                }
                .buttonStyle(.plain)

                if bwfPanelVisible {
                    Button { showBWFSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showBWFSettings, arrowEdge: .bottom) {
                        BWFSettingsPopover(selectedRaw: $bwfFieldsRaw)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 22)

            // ── Clip waveform — always present to keep lane canvas height stable ─
            let waveColor: Color = selectedClipTrackIdx.map { t in
                t < tracks.count ? trackColor(tracks[t], index: t) : Color.accentColor
            } ?? Color.accentColor
            ZStack {
                // Faint placeholder track so the area is visually defined even when empty
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.04))
                if let region = selectedRegion, let ap = audioPlayer {
                    // Composite waveform for the selected region
                    let segColors: [Color] = region.segments.map { seg in
                        seg.trackIdx < tracks.count
                            ? trackColor(tracks[seg.trackIdx], index: seg.trackIdx)
                            : waveColor
                    }
                    RegionWaveformView(region: region, segColors: segColors, audioPlayer: ap)
                } else if tc.selEnd != nil {
                    // Selection exists but exceeds the cap — don't try to play or preview it
                    Label("Selection too large to play (> 25 clips or > 2 min)",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if let clip = selectedClip, !clip.isGroup,
                          !waveChannelURLs.isEmpty, let ap = audioPlayer {
                    ClipWaveformView(clip: clip, channelURLs: waveChannelURLs,
                                     sampleRate: sr, color: waveColor, audioPlayer: ap)
                } else if let clip = selectedClip, !clip.isGroup, !clip.sourceFile.isEmpty,
                          waveChannelURLs.isEmpty {
                    // Clip is selected but source file is not on disk
                    Label("Audio file offline", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.7))
                } else {
                    // Hairline centre rule — gives the empty zone a hint of purpose
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 1)
                }
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            // ── BWF metadata panel ────────────────────────────────────────────
            if bwfPanelVisible {
                BWFMetadataPanel(
                    metadata:       bwfMetadata,
                    selectedFields: bwfSelectedFields,
                    sampleRate:     sr,
                    frameRate:      frameRate
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }

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
                                            // Clear any existing selection before starting fresh
                                            tc.selEnd      = nil
                                            tc.selTrackEnd = nil
                                            tc.selStart    = startFrac
                                            tc.selTrack    = laneIndex(at: val.startLocation.y,
                                                                       availH: geo.size.height)
                                        }
                                        tc.selEnd = curFrac
                                        let curLane = laneIndex(at: val.location.y,
                                                                 availH: geo.size.height)
                                        tc.selTrackEnd = curLane != tc.selTrack ? curLane : nil
                                    }
                                }
                                .onEnded { val in
                                    let wasDragging = isDragging
                                    isDragging = false
                                    isPanning  = false
                                    panOrigin  = nil

                                    let dist = hypot(val.translation.width, val.translation.height)
                                    if dist < 3 {
                                        // Click: place cursor, or select clip if one is under the click
                                        let frac      = (Double(val.location.x / geo.size.width)
                                            * tc.window + tc.viewStart).clamped(to: 0...1)
                                        let clickLane = laneIndex(at: val.location.y, availH: geo.size.height)
                                        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
                                        tc.isFocused  = true

                                        let clickedClip = clipAt(trackIdx: clickLane,
                                                                     sample: Int64(frac * total),
                                                                     respectHideMuted: hideMuted)

                                        if shiftHeld, tc.selStart != nil {
                                            applyShiftClick(clickedClip: clickedClip,
                                                            clickFrac: frac,
                                                            clickLane: clickLane,
                                                            total: total)
                                        } else if let clip = clickedClip {
                                            tc.selTrackEnd = nil
                                            tc.selTrack    = clickLane
                                            tc.selStart = Double(clip.startSample) / total
                                            tc.selEnd   = nil
                                        } else {
                                            tc.selTrackEnd = nil
                                            tc.selTrack    = clickLane
                                            tc.selStart = frac
                                            tc.selEnd   = nil
                                        }
                                    } else if wasDragging {
                                        // Normalize selection so start <= end
                                        if let s = tc.selStart, let e = tc.selEnd, e < s {
                                            let tmp = tc.selStart; tc.selStart = tc.selEnd; tc.selEnd = tmp
                                        }
                                        // Snap edges to actual clip bounds (trim leading/trailing silence)
                                        snapSelectionToClipBounds(total: total)
                                    }
                                }
                        )
                }
              )
            } // ScrollView

            // ── Ruler — pinned below tracks, always visible at any zoom ──────
            Canvas { ctx, size in
                let vStart      = tc.viewStart
                let vWindow     = tc.window
                let visibleSecs = vWindow * total / sr

                // Top hairline
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 0.5)),
                         with: .color(.secondary.opacity(0.35)))

                // ── TC ticks (top zone y 0…18) ────────────────────────────────
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

                // ── Memory location markers (bottom zone y 18…30) ─────────────
                if showMarkers {
                    var prevLabelX: CGFloat = -100
                    for loc in memoryLocations where loc.samplePosition > 0 {
                        let frac = Double(loc.samplePosition) / total
                        let x    = CGFloat((frac - vStart) / vWindow) * size.width
                        guard x >= -1, x <= size.width + 1 else { continue }
                        ctx.fill(Path(CGRect(x: x - 0.5, y: 18, width: 1, height: size.height - 18)),
                                 with: .color(.orange.opacity(0.7)))
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
        }
        .onAppear {
            tc.tracks       = tracks
            tc.totalSamples = allTracksSamples > 0 ? allTracksSamples : visibleMax
            tc.hideMuted    = hideMuted
            tc.startMonitoring()
        }
        .onDisappear {
            tc.stopMonitoring()
            audioPlayer?.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            audioPlayer?.stop()
        }
        .onChange(of: tracks)           { tc.tracks       = $0 }
        .onChange(of: allTracksSamples) { tc.totalSamples = $0 }
        .onChange(of: hideMuted)        { tc.hideMuted    = $0 }
        .onChange(of: tc.openTCEntry) { wants in
            guard wants else { return }
            tc.openTCEntry = false
            tcEntryText = tc.selStart.map { formatTC($0 * total / sr, fps: frameRate) } ?? ""
            showTCEntry = true
        }
        .onChange(of: tc.spacebarTapped) { _ in
            guard let ap = audioPlayer else { return }
            // Region selected → toggle region playback
            if let region = selectedRegion {
                if ap.isPlaying { ap.stop() }
                else { ap.playRegion(region) }
                return
            }
            // Single clip → existing behaviour
            guard let clip = selectedClip, !clip.isGroup,
                  let url = resolvedFiles.first(where: { $0.name == clip.sourceFile })?.url
            else { return }
            if ap.isPlaying && ap.playingClip == clip { ap.stop() }
            else { ap.play(clip: clip, url: url, sampleRate: sr) }
        }
        .onChange(of: tc.selStart) { newSelStart in
            // Autoplay on clip selection (click, tab, keyboard navigation).
            // Compute the clip from the NEW selStart so we never act on a stale capture.
            guard autoplay, tc.selEnd == nil, let newStart = newSelStart else { return }
            let newSamp = Int64((newStart * total).rounded())
            guard let clip = clipAt(trackIdx: tc.selTrack, sample: newSamp),
                  !clip.isGroup,
                  let ap = audioPlayer,
                  let url = resolvedFiles.first(where: { $0.name == clip.sourceFile })?.url
            else { return }
            guard !(ap.isPlaying && ap.playingClip == clip) else { return }
            ap.play(clip: clip, url: url, sampleRate: sr)
        }
        .onChange(of: tc.selEnd) { newSelEnd in
            // Autoplay when a region selection is completed (selEnd becomes non-nil).
            // Snap is handled in onEnded; this covers programmatic selEnd changes too.
            guard newSelEnd != nil, !isDragging, autoplay,
                  let ap = audioPlayer,
                  let region = selectedRegion else { return }
            ap.playRegion(region)
        }
        .onChange(of: selectedClip?.sourceFile) { sourceFile in
            // Resolve per-channel audio file URLs from the PTX clip data.
            if let clip = selectedClip, !clip.isGroup, clip.channelFiles.count >= 1 {
                waveChannelURLs = clip.channelFiles.compactMap { fn in resolvedFiles.first { $0.name == fn }?.url }
            } else {
                waveChannelURLs = []
            }
            // BWF metadata refresh
            guard bwfPanelVisible else { return }
            bwfMetadata = nil
            guard let name = sourceFile,
                  let url  = resolvedFiles.first(where: { $0.name == name })?.url else { return }
            Task.detached(priority: .userInitiated) {
                let m = BWFParser.parse(url: url)
                await MainActor.run { bwfMetadata = m }
            }
        }
    }

    /// Compact hover row — shows track/clip name only, no in/out/length.
    /// Used in the merged hover+toolbar row to save vertical space.
    private func hoverInfoRow(clip: PTXClip?, trackIdx: Int?,
                              sr: Double, total: Double,
                              resolvedURL: URL? = nil,
                              cursorAbsFrac: Double? = nil,
                              cursorLane: Int? = nil) -> some View {
        let color = trackIdx.map { t in
            t < tracks.count ? trackColor(tracks[t], index: t) : Color.secondary
        } ?? Color.secondary

        return HStack(spacing: 0) {
            Text("HOVER")
                .font(.system(size: 9).weight(.bold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .separatorColor).opacity(0.5)))
                .frame(width: 52, alignment: .leading)

            if let clip, let tIdx = trackIdx {
                let trackName = tIdx < tracks.count ? tracks[tIdx].name : ""
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.5))
                    .frame(width: 3, height: 14)
                    .padding(.trailing, 6)
                if !trackName.isEmpty {
                    Text(trackName)
                        .foregroundStyle(color.opacity(0.75))
                        .lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    Spacer().frame(width: 4)
                }
                Text(clip.name)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let absFrac = cursorAbsFrac {
                let laneIdx = cursorLane
                if let idx = laneIdx, idx < tracks.count {
                    let track  = tracks[idx]
                    let tcolor = trackColor(track, index: idx)
                    let fmt: String = track.type == .video
                        ? (tcFormat.isEmpty ? "Video" : "Video · \(tcFormat)")
                        : track.channelFormat
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(tcolor.opacity(0.5))
                        .frame(width: 3, height: 14)
                        .padding(.trailing, 6)
                    Text(track.name).foregroundStyle(tcolor.opacity(0.75)).lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    Spacer().frame(width: 4)
                    Text("[\(fmt)]").foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("—").foregroundStyle(.tertiary).padding(.leading, 8)
                }
                Spacer(minLength: 8)
                Group {
                    Text("pos ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    + Text(formatTC(absFrac * total / sr, fps: frameRate))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
            } else {
                Text("—").foregroundStyle(.tertiary).padding(.leading, 8)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.leading, 12)
    }

    @ViewBuilder
    private func spotButton(region: PlayRegion?, clip: PTXClip?,
                            resolvedFiles: [ResolvedAudioFile]) -> some View {
        if let region {
            Button {
                Task { try? await PTSLSessionInfo.shared.spotRegion(region) }
            } label: {
                Label("Spot \(region.totalClipCount) to PT", systemImage: "pin.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Spot all selected clips to their original Pro Tools timeline positions, with full source handles")
        } else if let clip, !clip.isGroup,
                  let url = resolvedFiles.first(where: { $0.name == clip.sourceFile })?.url {
            Button {
                let pool = resolvedFiles.compactMap(\.url)
                let segment = PlayRegion.TrackSegment(trackIdx: 0, clips: [(clip: clip, url: url)])
                let region  = PlayRegion(startSample: clip.startSample,
                                         endSample:   clip.startSample + clip.lengthSamples,
                                         segments:    [segment],
                                         sampleRate:  max(sampleRate, 1),
                                         resolvedPool: pool)
                Task { try? await PTSLSessionInfo.shared.spotRegion(region) }
            } label: {
                Label("Spot to PT", systemImage: "pin.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Spot this clip to the selected Pro Tools track with full source handles")
        }
    }

    private func clipInfoRow(clip: PTXClip?, trackIdx: Int?,
                             label: String, sr: Double, total: Double, isSelected: Bool,
                             resolvedURL: URL? = nil,
                             cursorAbsFrac: Double? = nil,
                             cursorLane: Int? = nil) -> some View {
        let color = trackIdx.map { t in
            t < tracks.count ? trackColor(tracks[t], index: t) : Color.secondary
        } ?? Color.secondary

        return HStack(spacing: 0) {
            // Label badge — fixed width keeps SELECT/HOVER columns aligned
            Text(label)
                .font(.system(size: 9).weight(.bold))
                .foregroundStyle(isSelected && clip != nil ? color : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected && clip != nil
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
                        .frame(width: 90, alignment: .leading)
                    Spacer().frame(width: 4)
                }

                // Clip name
                Text(clip.name)
                    .foregroundStyle(isSelected ? color : Color(nsColor: .secondaryLabelColor))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu {
                        if let url = resolvedURL {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(url.path,
                                                             inFileViewerRootedAtPath: "")
                            }
                        }
                    }
                if isSelected { clipCopyButton(clip.name) }

                if clip.isMuted {
                    Text("muted")
                        .font(.system(size: 9).weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1).padding(.leading, 4)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .separatorColor).opacity(0.6)))
                }
                if clip.isGroup {
                    Text("clip group")
                        .font(.system(size: 9).weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1).padding(.leading, 4)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .separatorColor).opacity(0.6)))
                }

                Spacer(minLength: 8)

                // In / Out / Length
                HStack(spacing: 0) {
                    Group {
                        Text("in ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        + Text(inTC).foregroundColor(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    }
                    .frame(width: 106, alignment: .trailing)
                    if isSelected { clipCopyButton(tcForPT(inTC)) }
                    Group {
                        Text("  out ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        + Text(outTC).foregroundColor(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    }
                    .frame(width: isSelected ? 108 : 118, alignment: .trailing)
                    if isSelected { clipCopyButton(tcForPT(outTC)) }
                    Group {
                        Text("  len ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        + Text(durTC).foregroundColor(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    }
                    .frame(width: 106, alignment: .trailing)
                    if isSelected { clipCopyButton(tcForPT(durTC)) }
                }

            } else if let absFrac = cursorAbsFrac {
                // No clip hovered — show lane name (if any) and cursor TC in the IN position
                let laneIdx = cursorLane
                if let idx = laneIdx, idx < tracks.count {
                    let track  = tracks[idx]
                    let tcolor = trackColor(track, index: idx)
                    let fmt: String = track.type == .video
                        ? (tcFormat.isEmpty ? "Video" : "Video · \(tcFormat)")
                        : track.channelFormat
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(tcolor.opacity(0.5))
                        .frame(width: 3, height: 14)
                        .padding(.trailing, 6)
                    Text(track.name).foregroundStyle(tcolor.opacity(0.75)).lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    Spacer().frame(width: 4)
                    Text("[\(fmt)]").foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("—").foregroundStyle(.tertiary).padding(.leading, 8)
                }
                Spacer(minLength: 8)
                // Cursor TC in the IN column position, styled to match
                HStack(spacing: 0) {
                    Group {
                        Text("pos ").foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        + Text(formatTC(absFrac * total / sr, fps: frameRate))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
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
        .background(isSelected && clip != nil
                    ? color.opacity(0.07)
                    : Color(nsColor: .separatorColor).opacity(0.05))
    }

    /// Zero-pad hours so PT gets a full HH:MM:SS:FF string it can accept via paste.
    private func tcForPT(_ tc: String) -> String {
        let parts = tc.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return tc }
        return parts.enumerated()
            .map { i, p in String(format: "%02d", Int(p) ?? 0) }
            .joined(separator: ":")
    }

    private func clipCopyButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.leading, 3)
        .help("Copy \"\(value)\"")
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

            // Pre-compute laneY for each track so the selection box can span exactly
            // the selected track rows rather than the full canvas height.
            var trackLaneYs: [CGFloat] = []
            do {
                var y: CGFloat = 0
                for (i, track) in tracks.enumerated() {
                    trackLaneYs.append(y)
                    y += scaledLaneH(track, index: i) + Self.laneGap
                }
            }

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

                // Precompute selection state for this track's clips
                let selStartSamp: Int64? = selStart.map { Int64(($0 * total).rounded()) }
                let selEndSamp:   Int64? = selEnd.map   { Int64(($0 * total).rounded()) }
                let trackInSelRange = isSelected   // track is within selTrack…selTrackEnd

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

                    // Selected-clip highlight: brighten by overlaying a white fill
                    let isClipSelected: Bool = {
                        if let ss = selEndSamp, trackInSelRange {
                            let selS = selStartSamp ?? 0
                            return clip.startSample < ss && clip.startSample + clip.lengthSamples > selS
                        } else if let ss = selStartSamp, i == (selTrack ?? -1), selEnd == nil {
                            return clip.startSample == ss
                        }
                        return false
                    }()
                    if isClipSelected, w >= 1 {
                        ctx.fill(Path(clipRect), with: .color(.white.opacity(0.28)))
                    }
                }
                laneY += thisLaneH + Self.laneGap
            }

            // Cursor / selection box (drawn over clips)
            if let sStart = selStart {
                let sx = CGFloat((sStart - vStart) / vWindow) * size.width
                if let sEnd = selEnd {
                    let ex = CGFloat((sEnd - vStart) / vWindow) * size.width
                    let x  = min(sx, ex)
                    let w  = max(1, abs(ex - sx))

                    // Clamp the box to the vertical span of the selected tracks.
                    let boxY: CGFloat
                    let boxH: CGFloat
                    if selLo >= 0, selLo < trackLaneYs.count {
                        boxY = trackLaneYs[selLo]
                        let hiIdx  = min(selHi, tracks.count - 1)
                        let bottom = trackLaneYs[hiIdx] + scaledLaneH(tracks[hiIdx], index: hiIdx)
                        boxH = max(1, bottom - boxY)
                    } else {
                        boxY = 0; boxH = availH
                    }

                    ctx.fill(
                        Path(CGRect(x: x, y: boxY, width: w, height: boxH)),
                        with: .color(Color.accentColor.opacity(0.22))
                    )
                    ctx.fill(Path(CGRect(x: x,         y: boxY, width: 1, height: boxH)),
                             with: .color(Color.accentColor.opacity(0.8)))
                    ctx.fill(Path(CGRect(x: x + w - 1, y: boxY, width: 1, height: boxH)),
                             with: .color(Color.accentColor.opacity(0.8)))
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

// MARK: - BWF Metadata Panel

private struct BWFMetadataPanel: View {
    let metadata:       BWFMetadata?
    let selectedFields: [BWFFieldKey]
    let sampleRate:     Double
    let frameRate:      Double

    var body: some View {
        VStack(spacing: 0) {
            if let meta = metadata {
                VStack(spacing: 1) {
                    ForEach(selectedFields) { key in
                        let value = meta.displayValue(for: key, sampleRate: sampleRate, frameRate: frameRate)
                        HStack(alignment: .top, spacing: 6) {
                            Text(key.label.uppercased())
                                .font(.system(size: 8).weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 88, alignment: .trailing)
                                .padding(.top, 1)
                            Text(value ?? "—")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(value != nil ? Color(nsColor: .labelColor) : Color.secondary)
                                .lineLimit(key == .bextCodingHistory ? 4 : 1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Color(nsColor: .separatorColor).opacity(0.04))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5))
            } else {
                HStack {
                    Spacer()
                    Text("No BWF metadata")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5))
            }
        }
    }
}

// MARK: - BWF Settings Popover

private struct BWFSettingsPopover: View {
    @Binding var selectedRaw: String

    private var selected: [BWFFieldKey] {
        selectedRaw.split(separator: ",").compactMap { BWFFieldKey(rawValue: String($0)) }
    }
    private func toggle(_ key: BWFFieldKey) {
        var current = selected
        if let idx = current.firstIndex(of: key) {
            current.remove(at: idx)
        } else {
            current.append(key)
        }
        selectedRaw = current.map(\.rawValue).joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BWF Fields")
                    .font(.system(size: 11).weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(BWFFieldKey.allCases) { key in
                        let isOn = selected.contains(key)
                        Button {
                            toggle(key)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.7))
                                    .font(.system(size: 12))
                                Text(key.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(nsColor: .labelColor))
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 200)
        .padding(.bottom, 8)
    }
}

// MARK: - Volume Fader

private struct VolumeFaderView: View {
    @Binding var volume: Float

    private let minDB: Double = -60
    private let maxDB: Double = +12
    private let knobW: CGFloat = 8

    private var dB: Double {
        volume > 0 ? 20 * log10(Double(volume)) : minDB
    }
    private func posFromDB(_ db: Double) -> Double {
        (db.clamped(to: minDB...maxDB) - minDB) / (maxDB - minDB)
    }
    private var faderPos: Double { posFromDB(dB) }
    private var unityPos: Double { posFromDB(0) }

    @State private var dragOriginPos: Double? = nil
    @State private var isHovering: Bool = false

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width - knobW
            let knobX  = CGFloat(faderPos) * trackW
            let unityX = CGFloat(unityPos) * trackW

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    .frame(height: 2)
                    .padding(.horizontal, knobW / 2)

                // Fill left of knob
                Capsule()
                    .fill(dB > 0.1
                          ? Color.orange.opacity(0.7)
                          : Color(nsColor: .secondaryLabelColor).opacity(0.5))
                    .frame(width: max(0, knobX), height: 2)
                    .padding(.leading, knobW / 2)

                // Unity notch
                Rectangle()
                    .fill(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 1, height: 5)
                    .offset(x: unityX + knobW / 2 - 0.5,
                            y: -1.5)

                // Knob
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .overlay(Circle().strokeBorder(
                        Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
                    .frame(width: knobW, height: knobW)
                    .offset(x: knobX)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        if dragOriginPos == nil { dragOriginPos = faderPos }
                        let delta = Double(val.translation.width / trackW)
                        let newPos = ((dragOriginPos ?? faderPos) + delta).clamped(to: 0...1)
                        let newDB = minDB + newPos * (maxDB - minDB)
                        volume = newDB <= minDB ? 0 : Float(pow(10, newDB / 20))
                    }
                    .onEnded { _ in dragOriginPos = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { volume = 1.0 })
        }
        .help(String(format: "%.1f dB  —  double-click to reset", dB))
    }
}

// MARK: - Clip Waveform View

private func waveformChannelLabels(_ count: Int) -> [String] {
    switch count {
    case 2: return ["L", "R"]
    case 3: return ["L", "R", "C"]
    case 4: return ["L", "R", "Ls", "Rs"]
    case 6: return ["L", "R", "C", "LFE", "Ls", "Rs"]
    case 8: return ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs"]
    default: return (1...max(count, 1)).map { "\($0)" }
    }
}

// MARK: - Region waveform (composite: clips + silence, one row per track segment)

private struct RegionWaveformView: View {
    let region:    PlayRegion
    let segColors: [Color]          // one Color per segment (in segment order)
    @ObservedObject var audioPlayer: AudioPlayer

    // trackIdx → assembled peak array (one Float per pixel)
    @State private var trackPeaks: [Int: [Float]] = [:]
    @State private var viewWidth:  CGFloat = 1
    @State private var loadID:     UUID    = UUID()

    var body: some View {
        Canvas { ctx, size in
            let w        = size.width
            let h        = size.height
            let segCount = CGFloat(region.segments.count)
            let rowH     = h / segCount

            for (rowIdx, segment) in region.segments.enumerated() {
                let rowY  = CGFloat(rowIdx) * rowH
                let midY  = rowY + rowH / 2
                let color = rowIdx < segColors.count ? segColors[rowIdx] : Color.accentColor

                // Silence baseline
                ctx.fill(Path(CGRect(x: 0, y: midY - 0.5, width: w, height: 1)),
                         with: .color(color.opacity(0.15)))

                // Clip presence bands (faint background where audio exists)
                let totalSamp = Double(region.endSample - region.startSample)
                for (clip, _) in segment.clips {
                    let x1 = CGFloat((Double(clip.startSample - region.startSample) / totalSamp) * Double(w))
                    let x2 = CGFloat((Double(clip.startSample + clip.lengthSamples - region.startSample) / totalSamp) * Double(w))
                    ctx.fill(Path(CGRect(x: x1, y: rowY, width: max(1, x2 - x1), height: rowH)),
                             with: .color(color.opacity(0.07)))
                }

                // Waveform peaks
                guard let peaks = trackPeaks[segment.trackIdx], !peaks.isEmpty else { continue }
                let n    = CGFloat(peaks.count)
                let step = w / n
                let lineW = max(1, step * 0.7)
                var path = Path()
                for (i, peak) in peaks.enumerated() {
                    let x   = (CGFloat(i) + 0.5) * step
                    let amp = CGFloat(peak) * (rowH / 2) * 0.85
                    path.move(to:    CGPoint(x: x, y: midY - amp))
                    path.addLine(to: CGPoint(x: x, y: midY + amp))
                }
                ctx.stroke(path, with: .color(color.opacity(0.85)),
                           style: StrokeStyle(lineWidth: lineW))

                // Row divider for multi-track
                if rowIdx > 0 {
                    ctx.fill(Path(CGRect(x: 0, y: rowY, width: w, height: 0.5)),
                             with: .color(.primary.opacity(0.1)))
                }
            }

            // Playhead
            if audioPlayer.isPlayingRegion || (audioPlayer.isPlaying && !audioPlayer.isPlayingRegion) {
                let x = CGFloat(audioPlayer.playbackFraction) * w
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)),
                         with: .color(.white.opacity(0.9)))
                ctx.fill(Path(CGRect(x: x - 2,   y: 0, width: 4, height: h)),
                         with: .color(.white.opacity(0.12)))
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear       { viewWidth = geo.size.width; loadID = UUID() }
                .onChange(of: geo.size.width) { viewWidth = $0; loadID = UUID() }
        })
        .task(id: loadID) { await loadPeaks() }
        .onChange(of: region.startSample) { _ in loadID = UUID() }
        .onChange(of: region.endSample)   { _ in loadID = UUID() }
    }

    private func loadPeaks() async {
        guard viewWidth > 1 else { return }
        let totalSamples = Double(region.endSample - region.startSample)
        let width        = Int(viewWidth)

        var result: [Int: [Float]] = [:]

        for segment in region.segments {
            var assembled = [Float](repeating: 0, count: width)

            for (clip, url) in segment.clips {
                let clipStartFrac = Double(clip.startSample - region.startSample) / totalSamples
                let clipEndFrac   = Double(clip.startSample + clip.lengthSamples - region.startSample) / totalSamples
                let pxStart = Int((clipStartFrac * Double(width)).rounded())
                let pxEnd   = Int((clipEndFrac   * Double(width)).rounded())
                let pxCount = max(1, pxEnd - pxStart)

                let chIdx     = AudioPlayer.channelIndex(fromClipName: clip.name)
                let clipPeaks = await AudioPlayer.loadWaveform(
                    url: url,
                    startSample: clip.sourceOffset,
                    lengthSamples: clip.lengthSamples,
                    sampleRate: region.sampleRate,
                    resolution: pxCount,
                    channelIndex: chIdx
                )
                guard let ch0 = clipPeaks.first else { continue }

                for (i, peak) in ch0.enumerated() {
                    let idx = pxStart + i
                    if idx >= 0 && idx < assembled.count { assembled[idx] = peak }
                }
            }
            result[segment.trackIdx] = assembled
        }

        await MainActor.run { trackPeaks = result }
    }
}

private struct ChannelLabelButton: View {
    let label:    String
    let isSoloed: Bool
    let action:   () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 7, weight: isSoloed ? .bold : .medium))
                .foregroundColor(isSoloed ? .accentColor : .secondary.opacity(0.6))
                .frame(width: 20)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Async waveform display for a resolved clip. Shows PCM peaks per channel,
/// with a moving playhead, click-to-seek, and per-channel solo (click label).
///
/// `channelURLs` drives the channel model:
///  - count == 1 → interleaved or mono file; `loadWaveform` returns all channels naturally.
///  - count  > 1 → multi-mono files; each URL is one channel (load as separate mono).
private struct ClipWaveformView: View {
    let clip:        PTXClip
    let channelURLs: [URL]   // one per channel (multi-mono) or single URL (interleaved/mono)
    let sampleRate:  Double
    let color:       Color
    @ObservedObject var audioPlayer: AudioPlayer

    @State private var peaks:       [[Float]] = []
    @State private var loadID:      UUID      = UUID()
    @State private var viewWidth:   CGFloat   = 1
    @State private var soloChannel: Int?      = nil  // nil = no solo

    private var primaryURL: URL { channelURLs.first! }
    private var isMultiMono: Bool { channelURLs.count > 1 }

    var body: some View {
        let chCount = peaks.count
        let labels  = waveformChannelLabels(chCount)
        let lw: CGFloat = chCount > 1 ? 20 : 0

        ZStack(alignment: .leading) {
            // ── Waveform canvas ─────────────────────────────────────────────
            Canvas { ctx, size in
                let w   = size.width
                let h   = size.height
                let mid = h / 2

                if peaks.isEmpty {
                    ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: w, height: 1)),
                             with: .color(.secondary.opacity(0.2)))
                } else {
                    let drawW = w - lw
                    let n     = CGFloat(peaks[0].count)
                    let bandH = h / CGFloat(chCount)
                    let step  = drawW / n
                    let lineW = max(1, step * 0.6)

                    for (ch, channelPeaks) in peaks.enumerated() {
                        let midY    = bandH * CGFloat(ch) + bandH / 2
                        let opacity = soloChannel == nil || soloChannel == ch ? 0.85 : 0.2
                        var path = Path()
                        for (i, peak) in channelPeaks.enumerated() {
                            let x   = lw + (CGFloat(i) + 0.5) * step
                            let amp = CGFloat(peak) * (bandH / 2) * 0.9
                            path.move(to:    CGPoint(x: x, y: midY - amp))
                            path.addLine(to: CGPoint(x: x, y: midY + amp))
                        }
                        ctx.stroke(path, with: .color(color.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: lineW))
                    }

                    if chCount > 1 {
                        var div = Path()
                        for ch in 1..<chCount {
                            let y = bandH * CGFloat(ch)
                            div.move(to:    CGPoint(x: 0, y: y))
                            div.addLine(to: CGPoint(x: w, y: y))
                        }
                        ctx.stroke(div, with: .color(Color.primary.opacity(0.15)),
                                   style: StrokeStyle(lineWidth: 0.5))
                    }
                }

                // Playhead
                if audioPlayer.playingClip == clip {
                    let x = CGFloat(audioPlayer.playbackFraction) * w
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)),
                             with: .color(.white.opacity(0.9)))
                    ctx.fill(Path(CGRect(x: x - 2,   y: 0, width: 4, height: h)),
                             with: .color(.white.opacity(0.12)))
                }
            }

            // ── Channel label buttons (multi-channel only) ───────────────────
            if chCount > 1 {
                VStack(spacing: 0) {
                    ForEach(0..<chCount, id: \.self) { ch in
                        ChannelLabelButton(
                            label:    ch < labels.count ? labels[ch] : "\(ch + 1)",
                            isSoloed: soloChannel == ch
                        ) {
                            soloChannel = soloChannel == ch ? nil : ch
                        }
                    }
                }
                .frame(width: 20)
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear       { viewWidth = geo.size.width }
                .onChange(of: geo.size.width) { viewWidth = $0 }
        })
        // Tap waveform area to seek / play (label column handled by buttons above)
        .onTapGesture { location in
            guard location.x > lw else { return }
            let fraction = max(0, min(1, (location.x - lw) / max(viewWidth - lw, 1)))
            if isMultiMono {
                // Multi-mono: play the specific channel file; default to first (L)
                let idx     = min(soloChannel ?? 0, channelURLs.count - 1)
                let playURL = channelURLs[idx]
                audioPlayer.play(clip: clip, url: playURL, sampleRate: sampleRate,
                                 fromFraction: fraction)
            } else {
                // Interleaved/mono: extract channel by index when soloed
                let chIdx = soloChannel   // nil = all channels
                audioPlayer.play(clip: clip, url: primaryURL, sampleRate: sampleRate,
                                 fromFraction: fraction, channelIndex: chIdx)
            }
        }
        .task(id: loadID) {
            peaks = []
            if isMultiMono {
                // Load each channel file as a separate mono peak array
                var result: [[Float]] = []
                for chURL in channelURLs {
                    let chPeaks = await AudioPlayer.loadWaveform(
                        url: chURL, startSample: clip.sourceOffset,
                        lengthSamples: clip.lengthSamples, sampleRate: sampleRate)
                    if let mono = chPeaks.first { result.append(mono) }
                }
                peaks = result
            } else {
                // Single URL: interleaved (returns all channels) or mono
                let chIdx = AudioPlayer.channelIndex(fromClipName: clip.name)
                peaks = await AudioPlayer.loadWaveform(
                    url: primaryURL, startSample: clip.sourceOffset,
                    lengthSamples: clip.lengthSamples, sampleRate: sampleRate,
                    channelIndex: chIdx)
            }
        }
        .onChange(of: clip)        { _ in loadID = UUID(); soloChannel = nil }
        .onChange(of: channelURLs) { _ in loadID = UUID(); soloChannel = nil }
    }
}
