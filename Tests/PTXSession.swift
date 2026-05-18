import Foundation

// MARK: - Session model

struct PTXSession {
    var sessionName:   String = ""
    var sessionPath:   String = ""

    // From binary (always available)
    var memoryLocations: [PTXMemoryLocation] = []
    var tracks:          [PTXTrack]          = []
    var audioFileNames:  [String]            = []   // base names without extension
    var audioFileMeta:   [(fileName: String, folderName: String)] = []  // parallel: full filename + subfolder

    // From PTSL (populated when PT is connected)
    var sampleRate:   String = ""   // e.g. "48000"
    var bitDepth:     String = ""   // e.g. "24"
    var tcFormat:     String = ""   // e.g. "29.97 DF", "25", "23.976"
    var sessionStart: String = ""
    var sessionLength: String = ""
    var plugins:         [String] = []
    var pluginSecondStrings: [String: String] = [:]

    /// Exact frame rate for TC math. Pulldown rates use rational values so that
    /// samples = nominalFrames × (sr / frameRate) works out to an exact integer.
    /// e.g. 23.976fps @ 48kHz → 48000/(24000/1001) = 2002 samples/frame exactly.
    var frameRate: Double {
        let s = tcFormat.components(separatedBy: " ").first ?? tcFormat
        switch s {
        case "23.976", "23.98": return 24000.0 / 1001.0   // 2002 samp/frame @ 48kHz
        case "24":              return 24
        case "25":              return 25
        case "29.97":           return 30000.0 / 1001.0   // 1601.6 samp/frame @ 48kHz (DF/NDF)
        case "30":              return 30
        case "47.95", "47.952": return 48000.0 / 1001.0
        case "48":              return 48
        case "50":              return 50
        case "59.94":           return 60000.0 / 1001.0
        case "60":              return 60
        default:                return 30
        }
    }

    // Resolved audio file URLs (matched from Audio Files/ folder)
    var resolvedAudioFiles: [ResolvedAudioFile] = []
}

struct PTXMemoryLocation {
    var number:         Int
    var name:           String
    var samplePosition: Int64 = 0
}

struct PTXTrack: Equatable {
    var index:        Int
    var name:         String
    var type:         PTXTrackType = .audio
    var channelCount: Int = 1       // 1=mono, 2=stereo, 6=5.1, etc.
    var isHidden:     Bool    = false
    var isInactive:   Bool    = false
    var folderName:   String? = nil   // non-nil when this track lives inside a folder
    var plugins:      [String] = []
    var clips:        [PTXClip] = []

    var channelFormat: String {
        if type == .video { return "Video" }
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
    case video      = "Video"
    case folder     = "Folder"
    case instrument = "Instrument"
    case unknown    = "Unknown"
}

struct PTXClip: Equatable {
    var name:        String
    var startSample: Int64  = 0
    var lengthSamples: Int64 = 0
    var sourceOffset: Int64  = 0    // offset into source audio file (samples)
    var sourceFile:  String = ""    // base filename (no extension)
    var isMuted:     Bool   = false
    var isGroup:     Bool   = false
}

struct ResolvedAudioFile: Identifiable {
    var id = UUID()
    var name:    String          // display name (without extension)
    var url:     URL?            // nil = file not found on disk
    var nodeID:  UInt32? = nil   // HFS+ catalog node ID from binary path data
    var tracks:  [String] = []   // which track names use this file

    var isOnline: Bool { url != nil }
}
