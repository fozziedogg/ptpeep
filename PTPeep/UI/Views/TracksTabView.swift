import AppKit
import SwiftUI

// MARK: - Track sort column

enum TrackSortColumn {
    case none, name, format, input, output, atmos
    var index: Int {
        switch self { case .none: 0; case .name: 1; case .format: 2; case .input: 3; case .output: 4; case .atmos: 5 }
    }
    init(index: Int) {
        switch index { case 1: self = .name; case 2: self = .format; case 3: self = .input; case 4: self = .output; case 5: self = .atmos; default: self = .none }
    }
}

// MARK: - Tracks tab

/// Extracted from SessionInspectorView. Keep this view small and its
/// closures free of large captures: the parent's body type was big enough
/// that view-value construction pinned the main thread on macOS 26.5.1
/// (Tests/ptpeep_sample4.txt) when wrapper-backed properties were read
/// inside closures during the post-resolution re-render.
struct TracksTabView: View {
    let tracks: [PTXTrack]
    let pluginSecondStrings: [String: String]
    @Binding var sortColumn: TrackSortColumn
    @Binding var sortAscending: Bool
    @Binding var hiddenTrackTypes: Set<PTXTrackType>
    @Binding var showTrackPlugins: Bool
    @Binding var showTrackSends: Bool
    @Binding var showTrackOptions: Bool

    @AppStorage("tl.showHiddenTracks")   private var tlShowHiddenTracks:   Bool = false
    @AppStorage("tl.showInactiveTracks") private var tlShowInactiveTracks: Bool = true
    @ObservedObject private var pluginScanner = PluginScanner.shared

    private var hasRoutingData: Bool { tracks.contains { $0.inputPath != nil || $0.outputPath != nil } }
    private var hasSendsData:   Bool { tracks.contains { !$0.sendPaths.isEmpty } }
    private var hasPlugins:     Bool { tracks.contains { !$0.plugins.isEmpty } }
    private var hasHiddenTracks:   Bool { tracks.contains { $0.isHidden } }
    private var hasInactiveTracks: Bool { tracks.contains { $0.isInactive } }
    private var hasAtmosData: Bool { tracks.contains { $0.isAtmosObject || $0.isAtmosBed } }

    private var presentTrackTypes: [PTXTrackType] {
        let order: [PTXTrackType] = [.audio, .instrument, .midi, .aux, .vca, .master, .folder, .video, .unknown]
        return order.filter { t in tracks.contains { $0.type == t } }
    }

    /// Filter + sort. Static and pure — closures capture only locals,
    /// never the view struct or property wrappers.
    private static func visibleTracks(
        _ tracks: [PTXTrack],
        hidden: Set<PTXTrackType>, showHidden: Bool, showInactive: Bool,
        col: TrackSortColumn, asc: Bool
    ) -> [PTXTrack] {
        let filtered = tracks.filter {
            !hidden.contains($0.type)
            && (showHidden   || !$0.isHidden)
            && (showInactive || !$0.isInactive)
        }
        switch col {
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
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            optionsBar
            columnHeader
            content
        }
    }

    private var optionsBar: some View {
        HStack(spacing: 0) {
            Spacer()
            let optionsActive = !hiddenTrackTypes.isEmpty || showTrackSends || showTrackPlugins
                             || tlShowHiddenTracks || !tlShowInactiveTracks
            Button { showTrackOptions.toggle() } label: {
                Image(systemName: optionsActive ? "ellipsis.circle.fill" : "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(optionsActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .popover(isPresented: $showTrackOptions, arrowEdge: .bottom) {
                optionsPopover
            }
        }
    }

    @ViewBuilder private var optionsPopover: some View {
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

    private var columnHeader: some View {
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
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private func sortableColumnHeader(_ title: String, col: TrackSortColumn,
                                      width: CGFloat, alignment: Alignment = .center) -> some View {
        Button {
            if col == .none { return }
            if sortColumn == col { sortAscending.toggle() }
            else { sortColumn = col; sortAscending = true }
        } label: {
            HStack(spacing: 2) {
                if alignment == .leading {
                    Text(title).font(.caption2)
                    if sortColumn == col {
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Text(title).font(.caption2)
                    if sortColumn == col {
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(sortColumn == col ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        let visible = Self.visibleTracks(
            tracks,
            hidden: hiddenTrackTypes,
            showHidden: tlShowHiddenTracks, showInactive: tlShowInactiveTracks,
            col: sortColumn, asc: sortAscending
        )
        let totalCount   = tracks.count
        let visibleCount = visible.count
        if tracks.isEmpty {
            PlaceholderRow(text: "No tracks found")
        } else {
            if visibleCount < totalCount || sortColumn != .none {
                HStack(spacing: 8) {
                    if visibleCount < totalCount {
                        Text("Showing \(visibleCount) of \(totalCount) tracks")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if sortColumn != .none {
                        Button("Session Order") {
                            sortColumn = .none
                            sortAscending = true
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
            ForEach(visible, id: \.index) { track in
                TrackRow(track: track, index: track.index, showPlugins: showTrackPlugins,
                         pluginInstalled: { name in
                             guard PluginScanner.shared.scanCompleted else { return nil }
                             return PluginScanner.shared.index?.contains(name, secondString: pluginSecondStrings[name])
                         },
                         showRouting: hasRoutingData, showSends: showTrackSends,
                         showAtmos: hasAtmosData, indentDepth: track.indentDepth)
            }
        }
    }
}
