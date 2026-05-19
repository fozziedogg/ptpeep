import Foundation

// MARK: - PTSL session metadata fetch
//
// Augments the binary-parsed PTXSession with live data from Pro Tools via PTSL gRPC.
// Requires Pro Tools 2022.12+ running with the target session open.
// Falls back silently if PT is not connected.

actor PTSLSessionInfo {

    static let shared = PTSLSessionInfo()

    // MARK: - Augment

    /// Fills in sample rate, bit depth, TC format, session length, and plugin list.
    /// Safe to call when PT is not running — returns without modifying `session`.
    func augment(session: inout PTXSession) async {
        guard let _ = try? await registerConnection() else { return }

        async let sr  = fetchSampleRate()
        async let bd  = fetchBitDepth()
        async let tc  = fetchTCFormat()
        async let len = fetchSessionLength()

        session.sampleRate    = (try? await sr)  ?? ""
        session.bitDepth      = (try? await bd)  ?? ""
        session.tcFormat      = (try? await tc)  ?? ""
        session.sessionLength = (try? await len) ?? ""

        if let trackList = try? await fetchTrackList() {
            mergeTrackTypes(trackList, into: &session)
        }
    }

    // MARK: - gRPC transport (raw HTTP/2 via URLSession)
    // Avoids adding grpc-swift dependency: sends raw gRPC-over-HTTP2 frames
    // to localhost:31416.  For simple unary calls this is straightforward.

    private var sessionId: String?
    private var ptslMajor: Int = 5
    private var ptslMinor: Int = 0

    // Private URLSession to avoid HTTP/2 connection-pooling issues with URLSession.shared.
    // Using ephemeral config so stale connections from before PT started are never reused.
    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 5
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    private func registerConnection() async throws -> String {
        if let sid = sessionId { return sid }
        let body = #"{"company_name":"Fozzie","application_name":"PTPeep"}"#
        let resp = try await sendPTSL(commandId: 70, body: body)
        guard let json = parseJSON(resp),
              let sid  = json["session_id"] as? String else {
            throw PTSLError.noSession
        }
        sessionId = sid
        try await fetchVersion()
        return sid
    }

    private func fetchVersion() async throws {
        let resp = try await sendPTSL(commandId: 55, body: "{}")
        guard let json = parseJSON(resp) else { return }
        ptslMajor = json["version"]       as? Int ?? 5
        ptslMinor = json["version_minor"] as? Int ?? 0
    }

    // MARK: - Metadata fetches

    private func fetchSampleRate() async throws -> String {
        let resp = try await sendPTSL(commandId: 35, body: "{}")
        guard let json = parseJSON(resp),
              let raw  = json["sample_rate"] as? String else { return "" }
        // "SRate_48000" → "48000"
        return raw
            .replacingOccurrences(of: "SRate_", with: "")
            .replacingOccurrences(of: "SR_",    with: "")
    }

    private func fetchBitDepth() async throws -> String {
        let resp = try await sendPTSL(commandId: 36, body: "{}")
        guard let json = parseJSON(resp),
              let raw  = json["bit_depth"] as? String else { return "" }
        // "Bit24" → "24"
        return raw.replacingOccurrences(of: "Bit", with: "")
    }

    private func fetchTCFormat() async throws -> String {
        let resp = try await sendPTSL(commandId: 38, body: "{}")
        guard let json = parseJSON(resp),
              let raw  = json["current_setting"] as? String else { return "" }
        return raw
    }

    private func fetchSessionLength() async throws -> String {
        let resp = try await sendPTSL(commandId: 45, body: "{}")
        guard let json = parseJSON(resp),
              let len  = json["session_length"] as? String else { return "" }
        return len
    }

    private func fetchTrackList() async throws -> [[String: Any]] {
        let body: String
        if ptslMajor > 2023 || (ptslMajor == 2023 && ptslMinor >= 9) {
            body = #"{"track_filter_list":[{"filter":"All","is_inverted":false}],"pagination_request":{"limit":500,"offset":0}}"#
        } else {
            body = #"{"track_filter_list":[{"filter":"All","is_inverted":false}]}"#
        }
        let resp = try await sendPTSL(commandId: 3, body: body)
        guard let json  = parseJSON(resp),
              let list  = json["track_list"] as? [[String: Any]] else { return [] }
        return list
    }

    // MARK: - Spot to Pro Tools

    /// Imports `sourceURL` into the open PT session, spotted so the clip's audio
    /// region (defined by `clip.sourceOffset` and `clip.startSample`) lands at the
    /// correct timeline timecode position.
    ///
    /// Uses PTSL command 2 (CId_Import / importType=Audio / ML_Spot).
    /// Fails silently if Pro Tools is not running.
    func spotClip(clip: PTXClip, sourceURL: URL,
                  sampleRate: Double, frameRate: Double) async throws {
        AppLog.shared.log("[Spot] Starting — file: \(sourceURL.lastPathComponent)")

        do {
            let sid = try await registerConnection()
            AppLog.shared.log("[Spot] PTSL connected, session_id: \(sid)")
        } catch {
            AppLog.shared.log("[Spot] PTSL connection failed: \(error)")
            throw PTSLError.notConnected
        }

        // The file's frame-0 must land at (startSample − sourceOffset) on the timeline
        // so that the clip region [sourceOffset … sourceOffset+length] sits at startSample.
        let spotSamples = max(Int64(0), clip.startSample - clip.sourceOffset)
        let tc = samplesToTC(spotSamples, sampleRate: sampleRate, frameRate: frameRate)
        AppLog.shared.log("[Spot] startSample=\(clip.startSample) sourceOffset=\(clip.sourceOffset) spotSamples=\(spotSamples) tc=\(tc)")

        let escapedPath = sourceURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let body = """
        {"importType":"Audio","audioData":{"fileList":["\(escapedPath)"],"audioOperations":"AddAudio","audioDestination":"MD_NewTrack","audioLocation":"ML_Spot","locationData":{"locationType":"Start","locationOptions":"TimeCode","locationValue":"\(tc)"}}}
        """
        AppLog.shared.log("[Spot] Sending body: \(body)")

        do {
            let resp = try await sendPTSL(commandId: 2, body: body)
            AppLog.shared.log("[Spot] Response: \(resp)")
        } catch {
            AppLog.shared.log("[Spot] sendPTSL failed: \(error)")
            throw error
        }
    }

    /// Convert an absolute sample position to an HH:MM:SS:FF timecode string.
    private func samplesToTC(_ samples: Int64, sampleRate: Double, frameRate: Double) -> String {
        let totalSecs = Double(samples) / max(sampleRate, 1)
        let h = Int(totalSecs) / 3600
        let m = (Int(totalSecs) % 3600) / 60
        let s = Int(totalSecs) % 60
        let f = Int((totalSecs - Double(Int(totalSecs))) * frameRate)
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    // MARK: - Track list merge

    private func mergeTrackTypes(_ ptslTracks: [[String: Any]], into session: inout PTXSession) {
        let typeMap: [String: PTXTrackType] = [
            "TT_Audio":      .audio,
            "TT_Midi":       .midi,
            "TT_Aux":        .aux,
            "TT_MasterFader": .master,
            "TT_VCA":        .vca,
            "TT_Instrument": .instrument,
        ]
        var nameToType: [String: PTXTrackType] = [:]
        for t in ptslTracks {
            if let name = t["name"] as? String,
               let typeStr = t["type"] as? String {
                nameToType[name] = typeMap[typeStr] ?? .unknown
            }
        }
        for i in session.tracks.indices {
            if let t = nameToType[session.tracks[i].name] {
                session.tracks[i].type = t
            }
        }
    }

    // MARK: - Raw gRPC/HTTP2 transport
    // Sends a PTSL JSON request using the minimal gRPC framing expected by PT.
    // No external dependencies — uses URLSession with HTTP/2.

    private func sendPTSL(commandId: Int, body: String) async throws -> String {
        // Build the JSON envelope PT expects
        let header: [String: Any] = [
            "command":       commandId,
            "version":       ptslMajor > 0 ? ptslMajor : 5,
            "version_minor": ptslMinor,
            "session_id":    sessionId ?? "",
            "task_id":       ""
        ]
        let envelope: [String: Any] = [
            "header":            header,
            "request_body_json": body
        ]

        // PT's gRPC server at :31416 accepts plain JSON over HTTP/1.1 in some versions,
        // but primarily expects gRPC-over-HTTP2. We use URLSession HTTP/2 with the
        // standard gRPC framing: 5-byte prefix (1 compression flag + 4-byte BE length).
        guard let url = URL(string: "http://localhost:31416/ptsl.PTSL/SendGrpcRequest") else {
            throw PTSLError.notConnected
        }

        let payload = try JSONSerialization.data(withJSONObject: envelope)

        // gRPC frame: [0x00][4-byte BE length][protobuf/json body]
        // PT accepts raw JSON wrapped in a gRPC frame when using content-type application/grpc+json
        var frame = Data([0x00])
        var len = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &len, count: 4))
        frame.append(payload)

        var req             = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod      = "POST"
        req.httpBody        = frame
        req.setValue("application/grpc+json", forHTTPHeaderField: "Content-Type")
        req.setValue("trailers", forHTTPHeaderField: "TE")

        let (responseData, _) = try await urlSession.data(for: req)

        // Strip 5-byte gRPC frame prefix from response
        guard responseData.count > 5 else { throw PTSLError.badResponse }
        let jsonData = responseData.dropFirst(5)
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let respBody = json["response_body_json"] as? String else {
            throw PTSLError.badResponse
        }
        return respBody
    }

    private func parseJSON(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j
    }

    // MARK: - Errors

    enum PTSLError: Error {
        case notConnected, noSession, badResponse
    }
}
