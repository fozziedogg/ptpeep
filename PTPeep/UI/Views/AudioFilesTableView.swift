import AppKit
import SwiftUI

// MARK: - Audio Files Table View

struct AudioFilesTableView: View {
    let audioFileNames: [String]
    let resolvedLookup: [String: ResolvedAudioFile]
    let bwfCache: [String: BWFMetadata]
    let selectedFields: [BWFFieldKey]
    let sampleRate: Double
    let frameRate: Double
    let highlightedFiles: Set<String>
    let isBWFLoading: Bool
    var onClearFilter: (() -> Void)? = nil
    @Binding var followClipSelection: Bool
    @Binding var bwfFieldsRaw: String
    @AppStorage("bwf.profiles")        private var profilesRaw: String = ""
    @AppStorage("bwf.activeProfileID") private var activeProfileIDRaw: String = ""
    @State private var showOptions: Bool = false
    @State private var sortColumn: SortColumn = .none
    @State private var sortAscending: Bool = true
    @State private var widthOverrides: [String: CGFloat] = [:]  // "name" or field rawValue → width
    @State private var autoWidthCache: [String: CGFloat] = [:] // cached auto-sized widths
    @State private var autoWidthCacheGen: Int = 0              // invalidation token
    @State private var dragColumnKey: String? = nil  // field being dragged for reorder

    private enum SortColumn: Equatable {
        case none
        case name
        case field(BWFFieldKey)
    }

    static let statusW: CGFloat = 20
    private static let colPad: CGFloat = 12
    private static let minColW: CGFloat = 40
    private static let rowFont  = Font.system(size: 10).monospacedDigit()
    private static let headerFont = Font.system(size: 9, weight: .semibold)

    private static func textWidth(_ s: String) -> CGFloat {
        CGFloat(s.count) * 6.2 + colPad
    }

    /// Auto-size width for a column; user overrides take precedence, then cached auto-width.
    private func nameWidth() -> CGFloat {
        if let w = widthOverrides["name"] { return w }
        if let w = autoWidthCache["name"] { return w }
        let maxName = audioFileNames.reduce("Name") { longest, n in n.count > longest.count ? n : longest }
        return min(400, max(100, Self.textWidth(maxName)))
    }

    private func fieldWidth(for key: BWFFieldKey) -> CGFloat {
        if let w = widthOverrides[key.rawValue] { return w }
        if let w = autoWidthCache[key.rawValue] { return w }
        // Fallback: header label width only (fast). Full data scan happens in rebuildAutoWidths().
        return max(50, Self.textWidth(key.label.uppercased()))
    }

    private var allFieldWidths: [CGFloat] {
        selectedFields.map { fieldWidth(for: $0) }
    }

    /// Recompute auto-widths from data. Called once when bwfCache changes, not per render.
    private func rebuildAutoWidths() {
        var cache: [String: CGFloat] = [:]
        // Name column
        let maxName = audioFileNames.reduce("Name") { longest, n in n.count > longest.count ? n : longest }
        cache["name"] = min(400, max(100, Self.textWidth(maxName)))
        // Field columns
        for key in BWFFieldKey.allCases {
            var longest = key.label.uppercased()
            for name in audioFileNames {
                if let meta = bwfCache[name],
                   let val = meta.displayValue(for: key, sampleRate: sampleRate, frameRate: frameRate),
                   val.count > longest.count {
                    longest = val
                }
            }
            cache[key.rawValue] = min(300, max(50, Self.textWidth(longest)))
        }
        autoWidthCache = cache
    }

    /// Pre-compute all display values + apply sorting.
    private var sortedRows: [(index: Int, name: String, resolved: ResolvedAudioFile?, values: [String?])] {
        var rows = audioFileNames.enumerated().map { i, name -> (index: Int, name: String, resolved: ResolvedAudioFile?, values: [String?]) in
            let meta = bwfCache[name]
            let vals = selectedFields.map { key in
                meta?.displayValue(for: key, sampleRate: sampleRate, frameRate: frameRate)
            }
            return (i, name, resolvedLookup[name], vals)
        }

        switch sortColumn {
        case .none:
            break
        case .name:
            rows.sort { a, b in
                sortAscending ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                              : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedDescending
            }
        case .field(let key):
            if let fi = selectedFields.firstIndex(of: key) {
                rows.sort { a, b in
                    let va = a.values[fi] ?? ""
                    let vb = b.values[fi] ?? ""
                    return sortAscending ? va.localizedCaseInsensitiveCompare(vb) == .orderedAscending
                                         : va.localizedCaseInsensitiveCompare(vb) == .orderedDescending
                }
            }
        }
        return rows
    }

    private func toggleSort(_ col: SortColumn) {
        if sortColumn == col {
            sortAscending.toggle()
        } else {
            sortColumn = col
            sortAscending = true
        }
    }

    private func sortIndicator(for col: SortColumn) -> String? {
        guard sortColumn == col else { return nil }
        return sortAscending ? "chevron.up" : "chevron.down"
    }

    // MARK: - Reorder helpers

    private func moveField(from src: String, to dest: String) {
        var fields = selectedFields
        guard let si = fields.firstIndex(where: { $0.rawValue == src }),
              let di = fields.firstIndex(where: { $0.rawValue == dest }),
              si != di else { return }
        let moved = fields.remove(at: si)
        fields.insert(moved, at: di)
        bwfFieldsRaw = fields.map(\.rawValue).joined(separator: ",")
    }

    // MARK: - Filtering

    private var isFiltering: Bool { highlightedFiles.count > 1 }

    private func displayRows(
        from rows: [(index: Int, name: String, resolved: ResolvedAudioFile?, values: [String?])]
    ) -> [(index: Int, name: String, resolved: ResolvedAudioFile?, values: [String?])] {
        isFiltering ? rows.filter { highlightedFiles.contains($0.name) } : rows
    }

    // MARK: - Body

    var body: some View {
        let nw = nameWidth()
        let fw = allFieldWidths
        let allRows = sortedRows
        let rows = displayRows(from: allRows)

        VStack(spacing: 0) {
            if audioFileNames.isEmpty {
                Spacer()
                Text("No audio files found")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                if isFiltering {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("Showing \(rows.count) of \(allRows.count) files")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show All") { onClearFilter?() }
                            .font(.system(size: 9))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.06))
                }

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Column header row
                        HStack(spacing: 0) {
                            Text("")
                                .frame(width: Self.statusW)
                            resizableHeaderCell(label: "NAME", width: nw, col: .name, widthKey: "name")
                            ForEach(Array(selectedFields.enumerated()), id: \.element) { fi, key in
                                resizableHeaderCell(
                                    label: key.label.uppercased(),
                                    width: fw[fi],
                                    col: .field(key),
                                    widthKey: key.rawValue
                                )
                                .onDrag {
                                    dragColumnKey = key.rawValue
                                    return NSItemProvider(object: key.rawValue as NSString)
                                }
                                .onDrop(of: [.text], delegate: FieldDropDelegate(
                                    targetKey: key.rawValue,
                                    dragColumnKey: $dragColumnKey,
                                    moveField: moveField
                                ))
                            }
                            if isBWFLoading {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 20, height: 14)
                                    .padding(.leading, 4)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                        .contextMenu { fieldContextMenu }

                        Divider()

                        // Vertically-scrollable rows
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(rows.enumerated()), id: \.offset) { displayIdx, row in
                                        AudioFileMetadataRow(
                                            name: row.name,
                                            isOnline: row.resolved?.url != nil,
                                            fileURL: row.resolved?.url,
                                            isHighlighted: highlightedFiles.contains(row.name),
                                            fieldValues: row.values,
                                            fieldWidths: fw,
                                            nameWidth: nw,
                                            index: displayIdx
                                        )
                                        .id("\(row.name)-\(row.index)")
                                    }
                                }
                            }
                            .onChange(of: highlightedFiles) { files in
                                if files.count == 1, let target = files.first,
                                   let row = rows.first(where: { $0.name == target }) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        proxy.scrollTo("\(row.name)-\(row.index)", anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button { showOptions = true } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                        audioFilesOptionsPopover
                    }
                }
            }
        }
        .onChange(of: bwfCache.count) { _ in rebuildAutoWidths() }
        .onAppear { rebuildAutoWidths() }
    }

    // MARK: - Header cell with resize handle

    private func resizableHeaderCell(label: String, width: CGFloat, col: SortColumn, widthKey: String) -> some View {
        HStack(spacing: 0) {
            Button { toggleSort(col) } label: {
                HStack(spacing: 2) {
                    Text(label)
                        .font(Self.headerFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let arrow = sortIndicator(for: col) {
                        Image(systemName: arrow)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { fieldContextMenu }

            // Drag handle for resizing — padding widens hit area without inflating height
            Color.secondary.opacity(0.3)
                .frame(width: 1)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            let newW = max(Self.minColW, width + drag.translation.width)
                            widthOverrides[widthKey] = newW
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
        .frame(width: width, height: 18)
        .clipped()
    }

    @ViewBuilder
    private var fieldContextMenu: some View {
        ForEach(BWFFieldKey.allCases) { key in
            let isOn = selectedFields.contains(key)
            Button {
                var current = selectedFields
                if let idx = current.firstIndex(of: key) {
                    current.remove(at: idx)
                } else {
                    current.append(key)
                }
                bwfFieldsRaw = current.map(\.rawValue).joined(separator: ",")
            } label: {
                if isOn {
                    Label(key.label, systemImage: "checkmark")
                } else {
                    Text(key.label)
                }
            }
        }
    }

    // MARK: - Options popover (follow-selection + profile switcher)

    private var audioFilesOptionsPopover: some View {
        let profiles = MetadataProfileStore.decode(profilesRaw)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                followClipSelection.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: followClipSelection ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(followClipSelection ? Color.accentColor : Color.secondary.opacity(0.7))
                        .font(.system(size: 12))
                    Text("Follow clip selection")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 4)

            Text("PROFILE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            ForEach(profiles) { p in
                Button {
                    // Set columns directly (we hold the binding) so the switch is
                    // immediate; persist the active id for the checkmark + Settings.
                    bwfFieldsRaw = p.fields.map(\.rawValue).joined(separator: ",")
                    activeProfileIDRaw = p.id.uuidString
                    showOptions = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: p.id.uuidString == activeProfileIDRaw ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(p.id.uuidString == activeProfileIDRaw ? Color.accentColor : Color.secondary.opacity(0.7))
                            .font(.system(size: 12))
                        Text(p.name)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 4)

            ManageProfilesButton { showOptions = false }
        }
        .frame(width: 200)
        .padding(.vertical, 4)
    }
}

// MARK: - Manage Profiles button

/// Opens the Settings window. Uses the AppKit Settings action (works on
/// macOS 13+); falls back to the older Preferences selector just in case.
private struct ManageProfilesButton: View {
    var onTap: () -> Void

    var body: some View {
        Button {
            onTap()
            openSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Manage Profiles…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

// MARK: - Drop delegate for reordering field columns

struct FieldDropDelegate: DropDelegate {
    let targetKey: String
    @Binding var dragColumnKey: String?
    let moveField: (String, String) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let src = dragColumnKey, src != targetKey else { return false }
        moveField(src, targetKey)
        dragColumnKey = nil
        return true
    }

    func dropEntered(info: DropInfo) {}
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {}
    func validateDrop(info: DropInfo) -> Bool { dragColumnKey != nil }
}

// MARK: - Audio file row

struct AudioFileMetadataRow: View {
    let name: String
    let isOnline: Bool
    let fileURL: URL?
    let isHighlighted: Bool
    let fieldValues: [String?]
    let fieldWidths: [CGFloat]
    let nameWidth: CGFloat
    let index: Int

    private static let statusW: CGFloat = AudioFilesTableView.statusW
    private static let rowFont = Font.system(size: 10).monospacedDigit()

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: isOnline ? "checkmark.circle" : "circle.dashed")
                .foregroundStyle(isOnline ? .green : .secondary)
                .font(.system(size: 10))
                .frame(width: Self.statusW)
            Text(name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: nameWidth, alignment: .leading)
            ForEach(Array(fieldValues.enumerated()), id: \.offset) { fi, value in
                Text(value ?? "—")
                    .font(Self.rowFont)
                    .foregroundStyle(value != nil ? Color.primary : Color.secondary.opacity(0.4))
                    .lineLimit(1)
                    .frame(width: fi < fieldWidths.count ? fieldWidths[fi] : 80, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(rowBackground)
        .contextMenu {
            if let url = fileURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                }
            }
        }
    }

    private var rowBackground: Color {
        if isHighlighted {
            return Color.accentColor.opacity(0.15)
        }
        return index % 2 == 0 ? Color.clear : Color.primary.opacity(0.03)
    }
}
