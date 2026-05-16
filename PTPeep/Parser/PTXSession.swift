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
    var plugins:         [String] = []
    /// Maps plugin display name → PTX second string (bundle ID or variant name).
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

    /// Sample rate as a Double (defaults to 48000 if not yet populated from PTSL).
    var sampleRateValue: Double { Double(sampleRate) ?? 48000.0 }

    /// Session timeline length in samples, parsed from the PTSL `sessionLength` timecode string.
    /// Returns nil when `sessionLength` is empty or unparseable.
    /// Supports "HH:MM:SS:FF" (frames) and "HH:MM:SS.mmm" (milliseconds) formats.
    var sessionLengthSamples: Int64? {
        guard !sessionLength.isEmpty else { return nil }
        let sr = sampleRateValue
        let fps = frameRate
        let s = sessionLength

        // Try HH:MM:SS:FF
        let colonParts = s.components(separatedBy: ":")
        if colonParts.count == 4,
           let hh = Int(colonParts[0]), let mm = Int(colonParts[1]),
           let ss = Int(colonParts[2]), let ff = Int(colonParts[3]) {
            let totalSeconds = Double(hh * 3600 + mm * 60 + ss)
            return Int64((totalSeconds * sr + Double(ff) * sr / fps).rounded())
        }
        // Try HH:MM:SS (no frames)
        if colonParts.count == 3,
           let hh = Int(colonParts[0]), let mm = Int(colonParts[1]),
           let ss = Double(colonParts[2]) {
            return Int64(((Double(hh * 3600 + mm * 60) + ss) * sr).rounded())
        }
        return nil
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
    var channelLabel: String? = nil // exact PT format label ("7.1", "5.1", etc.) when known
    var isHidden:     Bool    = false
    var isInactive:   Bool    = false
    var folderName:   String? = nil   // non-nil when this track lives inside a folder
    var colorIndex:   Int     = -1    // Pro Tools color index 0–55; -1 = no custom color
    var plugins:      [String] = []
    var clips:        [PTXClip] = []
    var inputPath:    String?  = nil   // I/O input bus name, e.g. "FULL MIX"
    var outputPath:   String?  = nil   // I/O output bus name, e.g. "STERO OUT"
    var isAtmosObject: Bool    = false // true = Atmos Object send
    var isAtmosBed:    Bool    = false // true = Atmos Bed send

    var channelFormat: String {
        switch type {
        case .video:  return "Video"
        case .vca: return ""
        case .folder:
            if inputPath == nil && outputPath == nil { return "" }  // Basic Folder — no routing
        default: break
        }
        // Prefer the exact label decoded from the PT format byte; fall back to count.
        if let label = channelLabel { return label }
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
    var sourceFile:  String = ""    // base filename (no extension)
    var isMuted:     Bool   = false
    var isGroup:     Bool   = false
}

struct ResolvedAudioFile: Identifiable {
    var id = UUID()
    var name:    String          // display name (without extension)
    var url:     URL
    var tracks:  [String] = []   // which track names use this file
}
