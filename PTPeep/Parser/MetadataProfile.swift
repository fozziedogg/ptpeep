import Foundation

/// A named, ordered selection of metadata fields to display in the Audio Files
/// table. Different editorial roles want different views (a dialogue editor
/// wants scene/take/roll; an SFX editor wants description/category/creator).
struct MetadataProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var fields: [BWFFieldKey]      // ordered → column order
    var builtIn: Bool              // seeded preset vs user-created

    init(id: UUID = UUID(), name: String, fields: [BWFFieldKey], builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.fields = fields
        self.builtIn = builtIn
    }
}

// BWFFieldKey persists by raw string, so unknown future cases decode away cleanly.
extension MetadataProfile {
    enum CodingKeys: String, CodingKey { case id, name, fields, builtIn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        builtIn = (try? c.decode(Bool.self, forKey: .builtIn)) ?? false
        let raws = try c.decode([String].self, forKey: .fields)
        fields = raws.compactMap { BWFFieldKey(rawValue: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(builtIn, forKey: .builtIn)
        try c.encode(fields.map(\.rawValue), forKey: .fields)
    }
}

// MARK: - Settings tabs

/// Tabs in the Settings window. Backed by @AppStorage("settings.selectedTab")
/// so other views (e.g. "Manage Profiles…") can deep-link to a tab.
enum SettingsTab: String {
    case general          = "general"
    case metadataProfiles = "metadataProfiles"

    static let storageKey = "settings.selectedTab"
}

// MARK: - Built-in presets

extension MetadataProfile {
    /// Stable IDs so presets survive re-seeding and aren't duplicated.
    static let dialogueID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    static let sfxID      = UUID(uuidString: "00000000-0000-0000-0000-0000000000F0")!
    static let musicID    = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!

    static let dialogue = MetadataProfile(
        id: dialogueID, name: "Dialogue",
        fields: [.ixmlScene, .ixmlTake, .ixmlTape, .ixmlTrackNames, .bextTimeReference, .ixmlNote],
        builtIn: true)

    static let sfx = MetadataProfile(
        id: sfxID, name: "SFX",
        fields: [.bextDescription, .bextOriginator, .ixmlTrackNames, .bextCodingHistory, .ixmlFileSampleRate],
        builtIn: true)

    static let music = MetadataProfile(
        id: musicID, name: "Music",
        fields: [.bextDescription, .bextOriginator, .bextDate, .bextVersion, .bextLoudness],
        builtIn: true)

    static let builtInPresets: [MetadataProfile] = [.dialogue, .sfx, .music]
}

// MARK: - Codec for @AppStorage persistence

/// JSON (de)serialization for the `[MetadataProfile]` stored in @AppStorage.
/// Kept as free functions so views own the @AppStorage (never an @Observable).
enum MetadataProfileStore {
    static func encode(_ profiles: [MetadataProfile]) -> String {
        guard let data = try? JSONEncoder().encode(profiles),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static func decode(_ json: String) -> [MetadataProfile] {
        guard let data = json.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([MetadataProfile].self, from: data)
        else { return [] }
        return profiles
    }

    /// Profiles from storage, seeding the built-in presets on first run / when
    /// missing. Returns `(profiles, changed)` — `changed` true if storage should
    /// be written back.
    static func loaded(from json: String) -> (profiles: [MetadataProfile], changed: Bool) {
        var profiles = decode(json)
        var changed = false
        if profiles.isEmpty {
            profiles = MetadataProfile.builtInPresets
            changed = true
        } else {
            // Re-add any built-in the user fully deleted? No — deletion is
            // intentional. Only seed when storage was empty/corrupt.
        }
        return (profiles, changed)
    }
}
