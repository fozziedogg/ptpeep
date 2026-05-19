import Foundation
#if PTSL_ENABLED
import GRPC
import NIOPosix
#endif

// MARK: - PTSL session metadata fetch
//
// Augments the binary-parsed PTXSession with live data from Pro Tools via PTSL gRPC.
// Requires Pro Tools 2022.12+ running with the target session open.
// Falls back silently if PT is not connected.
//
// Transport: grpc-swift 1.x over NIO (h2c cleartext to localhost:31416).
// URLSession cannot do HTTP/2 cleartext (h2c), causing -1005 errors with PT's gRPC
// server. The QL extension target does not link grpc-swift; augment() is a no-op there.

enum PTSLError: Error {
    case notConnected, noSession, badResponse
    case commandFailed(String)
}

actor PTSLSessionInfo {

    static let shared = PTSLSessionInfo()

    // MARK: - Augment

    /// Fills in sample rate, bit depth, TC format, session length, and track types.
    /// Safe to call when PT is not running — returns without modifying `session`.
    /// No-op in the Quick Look extension target (grpc-swift not linked there).
    func augment(session: inout PTXSession) async {
#if PTSL_ENABLED
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
#endif
    }

    // MARK: - Spot to Pro Tools

    /// Import `sourceURL` into the open PT session and place the clip at its original
    /// timeline position (defined by `clip.startSample` / `clip.sourceOffset`).
    ///
    /// PT 2025.06+: 3-step modern PTSL (cmds 123 → 127 → 124), sub-clip aware.
    /// PT 2024 and earlier: command 2 streaming Import with ML_Spot (creates a new track).
    func spotClip(clip: PTXClip, sourceURL: URL) async throws {
#if PTSL_ENABLED
        do {
            _ = try await registerConnection()
        } catch {
            throw error
        }

        if isPTSL2025_06orLater {
            let fileId = try await importAudioToClipList(path: sourceURL.path)
            let clipId = try await createAudioClip(
                fileId:        fileId,
                srcStart:      clip.sourceOffset,
                srcEnd:        clip.sourceOffset + clip.lengthSamples,
                timelineStart: clip.startSample,
                timelineEnd:   clip.startSample + clip.lengthSamples
            )
            try await spotClipByID(clipId: clipId, atSample: clip.startSample)
        } else {
            let playhead = (try? await fetchPlayheadSamples()) ?? 0
            try await importLegacy(path: sourceURL.path, spotSamples: playhead)
        }
#else
        throw PTSLError.notConnected
#endif
    }

#if PTSL_ENABLED
    // MARK: - gRPC client (grpc-swift / NIO — main app target only)

    private var sessionId:   String?
    private var ptslMajor:   Int = 5
    private var ptslMinor:   Int = 0
    private var _grpcClient: Ptsl_PTSLAsyncClient?

    private var isPTSL2025_06orLater: Bool {
        ptslMajor > 2025 || (ptslMajor == 2025 && ptslMinor >= 6)
    }

    private func grpcClient() -> Ptsl_PTSLAsyncClient {
        if let c = _grpcClient { return c }
        let group   = PlatformSupport.makeEventLoopGroup(loopCount: 1, networkPreference: .best)
        let channel = ClientConnection.insecure(group: group)
            .connect(host: "localhost", port: 31416)
        let client  = Ptsl_PTSLAsyncClient(channel: channel,
                                            defaultCallOptions: CallOptions(timeLimit: .timeout(.seconds(15))))
        _grpcClient = client
        return client
    }

    private func resetConnection() {
        sessionId   = nil
        _grpcClient = nil
        ptslMajor   = 5
        ptslMinor   = 0
    }

    private func sendRequest(commandId: Int, body: String, streaming: Bool = false) async throws -> String {
        var header          = Ptsl_RequestHeader()
        header.command      = Ptsl_CommandId(rawValue: commandId) ?? .cidNone
        header.version      = Int32(ptslMajor > 0 ? ptslMajor : 5)
        header.versionMinor = Int32(ptslMinor)
        header.sessionID    = sessionId ?? ""

        var req             = Ptsl_Request()
        req.header          = header
        req.requestBodyJson = body

        let response: Ptsl_Response
        do {
            if streaming {
                response = try await grpcClient().sendGrpcStreamingRequest(req)
            } else {
                response = try await grpcClient().sendGrpcRequest(req)
            }
        } catch {
            resetConnection()
            throw error
        }

        if response.header.status == .tstatusQueued {
            let taskId = response.header.taskID
            guard !taskId.isEmpty else { throw PTSLError.badResponse }
            try await pollUntilComplete(taskId: taskId)
            return response.responseBodyJson
        }

        guard response.header.status == .tstatusCompleted else {
            let msg = response.responseErrorJson.isEmpty
                ? "Command \(commandId) status \(response.header.status)"
                : response.responseErrorJson
            throw PTSLError.commandFailed(msg)
        }
        return response.responseBodyJson
    }

    private func pollUntilComplete(taskId: String) async throws {
        let timeout = Date().addingTimeInterval(60)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        while Date() < timeout {
            var hdr          = Ptsl_RequestHeader()
            hdr.command      = .cidGetTaskStatus
            hdr.version      = Int32(ptslMajor > 0 ? ptslMajor : 5)
            hdr.versionMinor = Int32(ptslMinor)
            hdr.sessionID    = sessionId ?? ""
            var req             = Ptsl_Request()
            req.header          = hdr
            req.requestBodyJson = #"{"task_id":"\#(taskId)"}"#
            let resp = try await grpcClient().sendGrpcRequest(req)
            switch resp.header.status {
            case .tstatusCompleted: return
            case .tstatusFailed:    throw PTSLError.commandFailed("Task \(taskId) failed")
            default:                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw PTSLError.commandFailed("Task \(taskId) timed out")
    }

    // MARK: - Connection

    private func registerConnection() async throws -> String {
        if let sid = sessionId { return sid }
        let body = #"{"company_name":"Fozzie","application_name":"PTPeep"}"#
        let resp = try await sendRequest(commandId: 70, body: body)
        guard let json = parseJSON(resp),
              let sid  = json["session_id"] as? String else { throw PTSLError.noSession }
        sessionId = sid
        try await fetchVersion()
        return sid
    }

    private func fetchVersion() async throws {
        let resp = try await sendRequest(commandId: 55, body: "{}")
        guard let json = parseJSON(resp) else { return }
        ptslMajor = json["version"]       as? Int ?? 5
        ptslMinor = json["version_minor"] as? Int ?? 0
    }

    // MARK: - Metadata fetches

    private func fetchSampleRate() async throws -> String {
        let resp = try await sendRequest(commandId: 35, body: "{}")
        guard let json = parseJSON(resp),
              let raw  = json["sample_rate"] as? String else { return "" }
        return raw
            .replacingOccurrences(of: "SRate_", with: "")
            .replacingOccurrences(of: "SR_",    with: "")
    }

    private func fetchBitDepth() async throws -> String {
        let resp = try await sendRequest(commandId: 36, body: "{}")
        guard let json = parseJSON(resp),
              let raw  = json["bit_depth"] as? String else { return "" }
        return raw.replacingOccurrences(of: "Bit", with: "")
    }

    private func fetchTCFormat() async throws -> String {
        let resp = try await sendRequest(commandId: 38, body: "{}")
        guard let json = parseJSON(resp),
              let raw  = json["current_setting"] as? String else { return "" }
        return raw
    }

    private func fetchSessionLength() async throws -> String {
        let resp = try await sendRequest(commandId: 45, body: "{}")
        guard let json = parseJSON(resp),
              let len  = json["session_length"] as? String else { return "" }
        return len
    }

    /// Returns the PT edit cursor position in samples (in_time from GetTimelineSelection, cmd 82).
    private func fetchPlayheadSamples() async throws -> Int64 {
        let body = isPTSL2025_06orLater
            ? #"{"location_type":"TLType_Samples"}"#
            : #"{"time_scale":"Samples"}"#
        let resp = try await sendRequest(commandId: 82, body: body)
        guard let json    = parseJSON(resp),
              let inStr   = json["in_time"] as? String,
              let samples = Int64(inStr) else { return 0 }
        return samples
    }

    private func fetchTrackList() async throws -> [[String: Any]] {
        let body: String
        if ptslMajor > 2023 || (ptslMajor == 2023 && ptslMinor >= 9) {
            body = #"{"track_filter_list":[{"filter":"All","is_inverted":false}],"pagination_request":{"limit":500,"offset":0}}"#
        } else {
            body = #"{"track_filter_list":[{"filter":"All","is_inverted":false}]}"#
        }
        let resp = try await sendRequest(commandId: 3, body: body)
        guard let json  = parseJSON(resp),
              let list  = json["track_list"] as? [[String: Any]] else { return [] }
        return list
    }

    private func mergeTrackTypes(_ ptslTracks: [[String: Any]], into session: inout PTXSession) {
        let typeMap: [String: PTXTrackType] = [
            "TT_Audio":       .audio,
            "TT_Midi":        .midi,
            "TT_Aux":         .aux,
            "TT_MasterFader": .master,
            "TT_VCA":         .vca,
            "TT_Instrument":  .instrument,
        ]
        var nameToType: [String: PTXTrackType] = [:]
        for t in ptslTracks {
            if let name    = t["name"]    as? String,
               let typeStr = t["type"]    as? String {
                nameToType[name] = typeMap[typeStr] ?? .unknown
            }
        }
        for i in session.tracks.indices {
            if let t = nameToType[session.tracks[i].name] {
                session.tracks[i].type = t
            }
        }
    }

    // MARK: - Spot helpers

    /// Legacy spot for PT 2024 and earlier (cmd 2, streaming).
    /// Places the clip on a NEW track at `spotSamples` from session start.
    /// The user must move it to the target track manually in PT.
    private func importLegacy(path: String, spotSamples: Int64) async throws {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body = """
        {
            "import_type": "Audio",
            "audio_data": {
                "file_list": ["\(escaped)"],
                "audio_operations": "ConvertAudio",
                "audio_destination": "MD_NewTrack",
                "audio_location": "ML_Spot",
                "location_data": {
                    "location_type": "Start",
                    "location_value": "\(spotSamples)",
                    "location_options": "Samples"
                }
            }
        }
        """
        AppLog.shared.log("[Spot] Legacy import (cmd 2) spot=\(spotSamples)")
        _ = try await sendRequest(commandId: 2, body: body, streaming: true)
    }

    private func importAudioToClipList(path: String) async throws -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let resp = try await sendRequest(commandId: 123,
                                         body: #"{"file_list":["\#(escaped)"]}"#)
        AppLog.shared.log("[Spot] ImportAudioToClipList: \(resp)")
        guard let json     = parseJSON(resp),
              let fileList = json["file_list"]              as? [[String: Any]],
              let first    = fileList.first,
              let destList = first["destination_file_list"] as? [[String: Any]],
              let dest     = destList.first,
              let fileId   = dest["file_id"]                as? String
        else { throw PTSLError.badResponse }
        return fileId
    }

    private func createAudioClip(fileId: String,
                                  srcStart: Int64, srcEnd: Int64,
                                  timelineStart: Int64, timelineEnd: Int64) async throws -> String {
        let body = """
        {"clip_list":[{"clip_info":[{\
        "file_id":"\(fileId)",\
        "src_start_point":{"position":\(srcStart),"time_type":"BTType_Samples"},\
        "src_end_point":{"position":\(srcEnd),"time_type":"BTType_Samples"},\
        "src_sync_point":{"position":\(srcStart),"time_type":"BTType_Samples"},\
        "start_point":{"position":\(timelineStart),"time_type":"BTType_Samples"},\
        "end_point":{"position":\(timelineEnd),"time_type":"BTType_Samples"}\
        }]}]}
        """
        let resp = try await sendRequest(commandId: 127, body: body)
        AppLog.shared.log("[Spot] CreateAudioClips: \(resp)")
        guard let json    = parseJSON(resp),
              let list    = json["clip_list"] as? [[String: Any]],
              let first   = list.first,
              let clipIds = first["clip_ids"] as? [String],
              let clipId  = clipIds.first
        else { throw PTSLError.badResponse }
        return clipId
    }

    private func spotClipByID(clipId: String, atSample: Int64) async throws {
        let body = """
        {"src_clips":["\(clipId)"],\
        "dst_location_data":{"location_type":"SLType_SyncPoint",\
        "location":{"location":"\(atSample)","time_type":"TLType_Samples"}}}
        """
        let resp = try await sendRequest(commandId: 124, body: body)
        AppLog.shared.log("[Spot] SpotClipsByID: \(resp)")
    }

    // MARK: - JSON helper

    private func parseJSON(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j
    }
#endif
}
