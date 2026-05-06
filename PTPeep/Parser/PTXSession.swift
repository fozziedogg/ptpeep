import Foundation

// MARK: - Session model

struct PTXSession {
    var sessionName:   String = ""
    var sessionPath:   String = ""

    // From binary (always available)
    var memoryLocations: [PTXMemoryLocation] = []
    var tracks:          [PTXTrack]          = []
    var audioFileNames:  [String]            = []   // base names without extension

    // From PTSL (populated when PT is connected)
    var sampleRate:   String = ""   // e.g. "48000"
    var bitDepth:     String = ""   // e.g. "24"
    var tcFormat:     String = ""   // e.g. "29.97"
    var sessionStart: String = ""
    var sessionLength: String = ""
    var plugins:      [String] = []

    // Resolved audio file URLs (matched from Audio Files/ folder)
    var resolvedAudioFiles: [ResolvedAudioFile] = []
}

struct PTXMemoryLocation {
    var number: Int
    var name:   String
}

struct PTXTrack {
    var index: Int
    var name:  String
    var type:  PTXTrackType = .audio
    var clips: [PTXClip]   = []
}

enum PTXTrackType: String {
    case audio      = "Audio"
    case midi       = "MIDI"
    case aux        = "Aux"
    case master     = "Master"
    case vca        = "VCA"
    case instrument = "Instrument"
    case unknown    = "Unknown"
}

struct PTXClip {
    var name:        String
    var startSample: Int64  = 0
    var lengthSamples: Int64 = 0
    var sourceFile:  String = ""    // base filename (no extension)
}

struct ResolvedAudioFile: Identifiable {
    var id = UUID()
    var name:    String          // display name (without extension)
    var url:     URL
    var tracks:  [String] = []   // which track names use this file
}
