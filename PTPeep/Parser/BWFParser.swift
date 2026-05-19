import Foundation

// MARK: - Field registry

enum BWFFieldKey: String, CaseIterable, Identifiable {
    // iXML chunk
    case ixmlScene      = "ixml.scene"
    case ixmlTake       = "ixml.take"
    case ixmlTape       = "ixml.tape"
    case ixmlNote       = "ixml.note"
    case ixmlCircled    = "ixml.circled"
    case ixmlTrackNames = "ixml.trackNames"
    // bext chunk
    case bextDescription   = "bext.description"
    case bextOriginator    = "bext.originator"
    case bextOriginatorRef = "bext.originatorRef"
    case bextDate          = "bext.date"
    case bextTime          = "bext.time"
    case bextTimeReference = "bext.timeReference"
    case bextVersion       = "bext.version"
    case bextUMID          = "bext.umid"
    case bextLoudness      = "bext.loudnessValue"
    case bextLoudnessRange = "bext.loudnessRange"
    case bextMaxTruePeak   = "bext.maxTruePeak"
    case bextMaxMomentary  = "bext.maxMomentary"
    case bextMaxShortTerm  = "bext.maxShortTerm"
    case bextCodingHistory = "bext.codingHistory"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ixmlScene:      return "Scene"
        case .ixmlTake:       return "Take"
        case .ixmlTape:       return "Roll"
        case .ixmlNote:       return "Note"
        case .ixmlCircled:    return "Circled"
        case .ixmlTrackNames: return "Channel Names"
        case .bextDescription:   return "Description"
        case .bextOriginator:    return "Originator"
        case .bextOriginatorRef: return "Originator Ref"
        case .bextDate:          return "Date"
        case .bextTime:          return "Time"
        case .bextTimeReference: return "TC Ref"
        case .bextVersion:       return "BWF Version"
        case .bextUMID:          return "UMID"
        case .bextLoudness:      return "Integrated Loudness"
        case .bextLoudnessRange: return "Loudness Range"
        case .bextMaxTruePeak:   return "Max True Peak"
        case .bextMaxMomentary:  return "Max Momentary"
        case .bextMaxShortTerm:  return "Max Short-Term"
        case .bextCodingHistory: return "Coding History"
        }
    }

    static let defaults: [BWFFieldKey] = [
        .ixmlScene, .ixmlTake, .ixmlTrackNames, .bextTimeReference, .bextDescription
    ]
}

// MARK: - Metadata model

struct BWFMetadata {
    // iXML
    var scene:         String?
    var take:          String?
    var tape:          String?
    var note:          String?
    var circled:       String?
    var trackNames:    [(channel: Int, name: String)] = []  // from TRACK_LIST
    // bext
    var description:   String?
    var originator:    String?
    var originatorRef: String?
    var date:          String?
    var time:          String?
    var timeReference: Int64?   // samples since midnight (raw)
    var version:       Int?
    var umid:          String?
    var loudness:      Double?  // LUFS
    var loudnessRange: Double?  // LU
    var maxTruePeak:   Double?  // dBTP
    var maxMomentary:  Double?  // LUFS
    var maxShortTerm:  Double?  // LUFS
    var codingHistory: String?

    /// Return a display string for the given field. Pass `sampleRate` for TC formatting.
    func displayValue(for key: BWFFieldKey, sampleRate: Double, frameRate: Double) -> String? {
        switch key {
        case .ixmlScene:      return scene
        case .ixmlTake:       return take
        case .ixmlTape:       return tape
        case .ixmlNote:       return note
        case .ixmlCircled:    return circled
        case .ixmlTrackNames:
            guard !trackNames.isEmpty else { return nil }
            return trackNames.map { "Ch\($0.channel): \($0.name)" }.joined(separator: "  ")
        case .bextDescription:   return description
        case .bextOriginator:    return originator
        case .bextOriginatorRef: return originatorRef
        case .bextDate:          return date
        case .bextTime:          return time
        case .bextTimeReference:
            guard let ref = timeReference, sampleRate > 0 else { return nil }
            let secs   = Double(ref) / sampleRate
            let h      = Int(secs / 3600)
            let m      = Int(secs.truncatingRemainder(dividingBy: 3600) / 60)
            let s      = Int(secs.truncatingRemainder(dividingBy: 60))
            let fps    = frameRate > 0 ? frameRate : 24
            let frames = Int((secs - floor(secs)) * fps)
            return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
        case .bextVersion:
            return version.map { "v\($0)" }
        case .bextUMID:          return umid
        case .bextLoudness:      return loudness.map      { String(format: "%.1f LUFS", $0) }
        case .bextLoudnessRange: return loudnessRange.map { String(format: "%.1f LU",   $0) }
        case .bextMaxTruePeak:   return maxTruePeak.map   { String(format: "%.1f dBTP", $0) }
        case .bextMaxMomentary:  return maxMomentary.map  { String(format: "%.1f LUFS", $0) }
        case .bextMaxShortTerm:  return maxShortTerm.map  { String(format: "%.1f LUFS", $0) }
        case .bextCodingHistory: return codingHistory
        }
    }
}

// MARK: - Parser

enum BWFParser {
    static func parse(url: URL) -> BWFMetadata? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> BWFMetadata? {
        // Validate RIFF/WAVE header
        guard data.count > 12,
              data[0..<4] == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else { return nil }

        var meta   = BWFMetadata()
        var hasBWF = false
        var offset = 12

        while offset + 8 <= data.count {
            let id       = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size     = Int(data.readUInt32LE(at: offset + 4))
            let dataStart = offset + 8

            switch id {
            case "bext":
                parseBext(data: data, start: dataStart, size: size, into: &meta)
                hasBWF = true
            case "iXML":
                parseIXML(data: data, start: dataStart, size: size, into: &meta)
                hasBWF = true
            default:
                break
            }

            // Chunks are word-aligned (padded to even byte boundary)
            let next = dataStart + size + (size & 1)
            guard next > offset else { break }
            offset = next
        }

        return hasBWF ? meta : nil
    }

    // MARK: bext

    private static func parseBext(data: Data, start: Int, size: Int, into meta: inout BWFMetadata) {
        // EBU Tech 3285 bext chunk layout (offsets relative to chunk data start):
        //   0   Description          256 bytes
        // 256   Originator            32 bytes
        // 288   OriginatorReference   32 bytes
        // 320   OriginationDate       10 bytes  (YYYY-MM-DD)
        // 330   OriginationTime        8 bytes  (HH:MM:SS)
        // 338   TimeReferenceLow       4 bytes  LE uint32
        // 342   TimeReferenceHigh      4 bytes  LE uint32
        // 346   Version                2 bytes  LE uint16
        // 348   UMID                  64 bytes
        // 412   LoudnessValue          2 bytes  LE int16  (/100 → LUFS)   V2+
        // 414   LoudnessRange          2 bytes  LE int16  (/100 → LU)     V2+
        // 416   MaxTruePeakLevel       2 bytes  LE int16  (/100 → dBTP)   V2+
        // 418   MaxMomentaryLoudness   2 bytes  LE int16  (/100 → LUFS)   V2+
        // 420   MaxShortTermLoudness   2 bytes  LE int16  (/100 → LUFS)   V2+
        // 422   Reserved             180 bytes
        // 602   CodingHistory        variable (null-padded)

        func fixedStr(_ off: Int, _ len: Int) -> String? {
            let s = start + off, e = min(s + len, data.count)
            guard s < e else { return nil }
            let trimmed = data[s..<e].prefix(while: { $0 != 0 })
            guard !trimmed.isEmpty else { return nil }
            return String(bytes: trimmed, encoding: .utf8)
                ?? String(bytes: trimmed, encoding: .isoLatin1)
        }

        meta.description   = fixedStr(0,   256)
        meta.originator    = fixedStr(256,  32)
        meta.originatorRef = fixedStr(288,  32)
        meta.date          = fixedStr(320,  10)
        meta.time          = fixedStr(330,   8)

        if size >= 346, start + 345 < data.count {
            let lo = UInt64(data.readUInt32LE(at: start + 338))
            let hi = UInt64(data.readUInt32LE(at: start + 342))
            meta.timeReference = Int64(bitPattern: (hi << 32) | lo)
        }
        if size >= 348, start + 347 < data.count {
            meta.version = Int(data.readUInt16LE(at: start + 346))
        }
        if size >= 412, start + 411 < data.count {
            let umidBytes = data[(start+348)..<min(start+412, data.count)]
            if umidBytes.contains(where: { $0 != 0 }) {
                meta.umid = umidBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    .components(separatedBy: " ")
                    .enumerated()
                    .map { $0.offset % 4 == 0 && $0.offset > 0 ? ".\($0.element)" : $0.element }
                    .joined()
            }
        }
        if let ver = meta.version, ver >= 2, size >= 422, start + 421 < data.count {
            func loudnessField(at off: Int) -> Double? {
                let raw = data.readInt16LE(at: start + off)
                guard raw != Int16(bitPattern: 0x7FFF) else { return nil }
                return Double(raw) / 100.0
            }
            meta.loudness      = loudnessField(at: 412)
            meta.loudnessRange = loudnessField(at: 414)
            meta.maxTruePeak   = loudnessField(at: 416)
            meta.maxMomentary  = loudnessField(at: 418)
            meta.maxShortTerm  = loudnessField(at: 420)
        }
        if size > 602 {
            let s = start + 602, e = min(s + size - 602, data.count)
            if s < e {
                let trimmed = data[s..<e].prefix(while: { $0 != 0 })
                if !trimmed.isEmpty {
                    meta.codingHistory = String(bytes: trimmed, encoding: .utf8)
                        ?? String(bytes: trimmed, encoding: .isoLatin1)
                }
            }
        }
    }

    // MARK: iXML

    private static func parseIXML(data: Data, start: Int, size: Int, into meta: inout BWFMetadata) {
        let end = min(start + size, data.count)
        guard start < end,
              let xml = String(data: data[start..<end], encoding: .utf8)
                     ?? String(data: data[start..<end], encoding: .isoLatin1)
        else { return }

        meta.scene   = tag(in: xml, "SCENE")
        meta.take    = tag(in: xml, "TAKE")
        meta.tape    = tag(in: xml, "TAPE")
        meta.note    = tag(in: xml, "NOTE")
        meta.circled = tag(in: xml, "CIRCLED")

        // Parse TRACK_LIST — each <TRACK> has <CHANNEL_INDEX> and <NAME>
        var searchFrom = xml.startIndex
        while let t1 = xml.range(of: "<TRACK>", range: searchFrom..<xml.endIndex),
              let t2 = xml.range(of: "</TRACK>", range: t1.upperBound..<xml.endIndex) {
            let trackXML = String(xml[t1.upperBound..<t2.lowerBound])
            if let name = tag(in: trackXML, "NAME"),
               let chStr = tag(in: trackXML, "CHANNEL_INDEX"),
               let ch = Int(chStr) {
                meta.trackNames.append((channel: ch, name: name))
            }
            searchFrom = t2.upperBound
        }
        meta.trackNames.sort { $0.channel < $1.channel }
    }

    private static func tag(in xml: String, _ name: String) -> String? {
        guard let r1 = xml.range(of: "<\(name)>"),
              let r2 = xml.range(of: "</\(name)>", range: r1.upperBound..<xml.endIndex)
        else { return nil }
        let v = String(xml[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

// MARK: - Data helpers (file-private)

private extension Data {
    func readUInt32LE(at i: Int) -> UInt32 {
        guard i + 3 < count else { return 0 }
        return UInt32(self[i]) | UInt32(self[i+1]) << 8
             | UInt32(self[i+2]) << 16 | UInt32(self[i+3]) << 24
    }
    func readUInt16LE(at i: Int) -> UInt16 {
        guard i + 1 < count else { return 0 }
        return UInt16(self[i]) | UInt16(self[i+1]) << 8
    }
    func readInt16LE(at i: Int) -> Int16 {
        Int16(bitPattern: readUInt16LE(at: i))
    }
}
