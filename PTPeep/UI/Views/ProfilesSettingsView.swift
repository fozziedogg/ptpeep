import SwiftUI

/// Settings tab for managing metadata view profiles (Dialogue / SFX / Music /
/// custom). Master list on the left, field editor on the right.
struct ProfilesSettingsView: View {
    @AppStorage("bwf.profiles")        private var profilesRaw: String = ""
    @AppStorage("bwf.activeProfileID") private var activeProfileIDRaw: String = ""

    @State private var profiles: [MetadataProfile] = []
    @State private var selectedID: MetadataProfile.ID?

    var body: some View {
        HStack(spacing: 0) {
            profileList
            Divider()
            detailPane
        }
        .frame(width: 560, height: 420)
        .onAppear(perform: load)
        .onChange(of: profiles) { persist($0) }
    }

    // MARK: Master list

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(profiles) { profile in
                    HStack(spacing: 6) {
                        Image(systemName: activeProfileIDRaw == profile.id.uuidString
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(activeProfileIDRaw == profile.id.uuidString
                                             ? Color.accentColor : Color.secondary)
                            .onTapGesture { activeProfileIDRaw = profile.id.uuidString }
                            .help("Make active")
                        Text(profile.name)
                        if profile.builtIn {
                            Text("preset").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(profile.id)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 2) {
                Button(action: addProfile) { Image(systemName: "plus") }
                    .help("New profile")
                Button(action: duplicateSelected) { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate")
                    .disabled(selected == nil)
                Button(action: deleteSelected) { Image(systemName: "minus") }
                    .help("Delete")
                    .disabled(selected == nil || profiles.count <= 1)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(width: 200)
    }

    // MARK: Detail editor

    @ViewBuilder private var detailPane: some View {
        if let idx = selectedIndex {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Profile name", text: $profiles[idx].name)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)

                Text("Columns (drag to reorder)")
                    .font(.caption).foregroundStyle(.secondary)

                List {
                    ForEach(profiles[idx].fields) { key in
                        HStack {
                            Text(key.label)
                            Spacer()
                            Text(key.group.title).font(.caption2).foregroundStyle(.tertiary)
                            Button {
                                profiles[idx].fields.removeAll { $0 == key }
                            } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onMove { profiles[idx].fields.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 160)

                HStack {
                    addFieldMenu(profileIndex: idx)
                    Spacer()
                    Text("\(profiles[idx].fields.count) columns")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Select a profile")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addFieldMenu(profileIndex idx: Int) -> some View {
        Menu {
            ForEach(FieldGroup.allCases) { group in
                let avail = group.fields.filter { !profiles[idx].fields.contains($0) }
                if !avail.isEmpty {
                    Section(group.title) {
                        ForEach(avail) { key in
                            Button(key.label) { profiles[idx].fields.append(key) }
                        }
                    }
                }
            }
        } label: {
            Label("Add Field", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Data

    private var selected: MetadataProfile? {
        profiles.first { $0.id == selectedID }
    }
    private var selectedIndex: Int? {
        profiles.firstIndex { $0.id == selectedID }
    }

    private func load() {
        let (list, changed) = MetadataProfileStore.loaded(from: profilesRaw)
        profiles = list
        if changed { profilesRaw = MetadataProfileStore.encode(list) }
        if selectedID == nil {
            selectedID = list.first { $0.id.uuidString == activeProfileIDRaw }?.id ?? list.first?.id
        }
    }

    private func persist(_ list: [MetadataProfile]) {
        let json = MetadataProfileStore.encode(list)
        if json != profilesRaw { profilesRaw = json }
    }

    private func addProfile() {
        let new = MetadataProfile(name: "New Profile", fields: BWFFieldKey.defaults)
        profiles.append(new)
        selectedID = new.id
    }

    private func duplicateSelected() {
        guard let s = selected else { return }
        let copy = MetadataProfile(name: "\(s.name) Copy", fields: s.fields)
        profiles.append(copy)
        selectedID = copy.id
    }

    private func deleteSelected() {
        guard let id = selectedID, profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        // Re-point active profile if we deleted it.
        if activeProfileIDRaw == id.uuidString {
            activeProfileIDRaw = profiles.first?.id.uuidString ?? ""
        }
        selectedID = profiles.first?.id
    }
}
