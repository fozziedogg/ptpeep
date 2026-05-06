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
    var tcFormat:     String = ""   // e.g. "29.97 DF", "25", "23.976"
    var sessionStart: String = ""
    var sessionLength: String = ""
    var plugins:      [String] = []

    /// Nominal frame rate parsed from tcFormat. Defaults to 29.97 if unknown.
    var frameRate: Double {
        let s = tcFormat.components(separatedBy: " ").first ?? tcFormat
        switch s {
        case "23.976", "23.98": return 24        // count 24 frames per second
        case "24":              return 24
        case "25":              return 25
        case "29.97":           return 30         // count 30 frames per second (DF/NDF)
        case "30":              return 30
        case "47.95", "47.952": return 48
        case "48":              return 48
        case "50":              return 50
        case "59.94":           return 60
        case "60":              return 60
        default:                return 30
        }
    }

    // Resolved audio file URLs (matched from Audio Files/ folder)
    var resolvedAudioFiles: [ResolvedAudioFile] = []
}

struct PTXMemoryLocation {
    var number: Int
    var name:   String
}

struct PTXTrack {
    var index:        Int
    var name:         String
    var type:         PTXTrackType = .audio
    var channelCount: Int = 1       // 1=mono, 2=stereo, 6=5.1, etc.
    var isHidden:     Bool    = false
    var folderName:   String? = nil   // non-nil when this track lives inside a folder
    var clips:        [PTXClip] = []

    var channelFormat: String {
        switch channelCount {
        case 1:  return "Mono"
        case 2:  return "Stereo"
        case 3:  return "LCR"
        case 4:  return "Quad"
        case 5:  return "5.0"
        case 6:  return "5.1"
        case 8:  return "7.1"
        default: return "\(channelCount)ch"
        }
    }
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
