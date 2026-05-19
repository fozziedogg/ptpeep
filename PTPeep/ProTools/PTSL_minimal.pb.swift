// Hand-written Swift types matching what protoc-gen-swift generates for
// sdk/PTSL_minimal.proto (package ptsl). Only the types PTSLClient uses.

import SwiftProtobuf
import Foundation

// MARK: - Enums
// SwiftProtobuf enums must NOT carry a Swift raw type because UNRECOGNIZED(Int)
// has an associated value. RawRepresentable is satisfied manually below.

enum Ptsl_CommandId: SwiftProtobuf.Enum {
    typealias RawValue = Int
    case cidNone
    case cidImport
    case cidGetSessionSampleRate
    case cidGetPtslVersion
    case cidRegisterConnection
    case cidGetTimelineSelection
    case cidGetTaskStatus
    case cidImportAudioToClipList
    case cidSpotClipsByID
    case cidCreateAudioClips
    case UNRECOGNIZED(Int)

    init() { self = .cidNone }

    init?(rawValue: Int) {
        switch rawValue {
        case 0:   self = .cidNone
        case 2:   self = .cidImport
        case 12:  self = .cidGetTaskStatus
        case 35:  self = .cidGetSessionSampleRate
        case 55:  self = .cidGetPtslVersion
        case 70:  self = .cidRegisterConnection
        case 82:  self = .cidGetTimelineSelection
        case 123: self = .cidImportAudioToClipList
        case 124: self = .cidSpotClipsByID
        case 127: self = .cidCreateAudioClips
        default:  self = .UNRECOGNIZED(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .cidNone:                   return 0
        case .cidImport:                 return 2
        case .cidGetTaskStatus:          return 12
        case .cidGetSessionSampleRate:   return 35
        case .cidGetPtslVersion:         return 55
        case .cidRegisterConnection:     return 70
        case .cidGetTimelineSelection:   return 82
        case .cidImportAudioToClipList:  return 123
        case .cidSpotClipsByID:          return 124
        case .cidCreateAudioClips:       return 127
        case .UNRECOGNIZED(let v):       return v
        }
    }
}

enum Ptsl_TaskStatus: SwiftProtobuf.Enum {
    typealias RawValue = Int
    case tstatusQueued
    case tstatusPending
    case tstatusInProgress
    case tstatusCompleted
    case tstatusFailed
    case UNRECOGNIZED(Int)

    init() { self = .tstatusQueued }

    init?(rawValue: Int) {
        switch rawValue {
        case 0: self = .tstatusQueued
        case 1: self = .tstatusPending
        case 2: self = .tstatusInProgress
        case 3: self = .tstatusCompleted
        case 4: self = .tstatusFailed
        default: self = .UNRECOGNIZED(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .tstatusQueued:       return 0
        case .tstatusPending:      return 1
        case .tstatusInProgress:   return 2
        case .tstatusCompleted:    return 3
        case .tstatusFailed:       return 4
        case .UNRECOGNIZED(let v): return v
        }
    }
}

// MARK: - Messages
// Conforming to _MessageImplementationBase (Message + Hashable) gives us
// the default isEqualTo(message:) implementation that Message requires.

struct Ptsl_RequestHeader: SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName = "ptsl.RequestHeader"

    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "task_id"),
        2: .same(proto: "command"),
        3: .same(proto: "version"),
        4: .same(proto: "session_id"),
        5: .same(proto: "version_minor"),
        6: .same(proto: "version_revision"),
    ]

    var taskID:          String          = ""
    var command:         Ptsl_CommandId  = .cidNone
    var version:         Int32           = 0
    var sessionID:       String          = ""
    var versionMinor:    Int32           = 0
    var versionRevision: Int32           = 0
    var unknownFields    = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let f = try decoder.nextFieldNumber() {
            switch f {
            case 1: try decoder.decodeSingularStringField(value: &taskID)
            case 2: try decoder.decodeSingularEnumField(value: &command)
            case 3: try decoder.decodeSingularInt32Field(value: &version)
            case 4: try decoder.decodeSingularStringField(value: &sessionID)
            case 5: try decoder.decodeSingularInt32Field(value: &versionMinor)
            case 6: try decoder.decodeSingularInt32Field(value: &versionRevision)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !taskID.isEmpty      { try visitor.visitSingularStringField(value: taskID,         fieldNumber: 1) }
        if command != .cidNone  { try visitor.visitSingularEnumField(value: command,          fieldNumber: 2) }
        if version != 0         { try visitor.visitSingularInt32Field(value: version,         fieldNumber: 3) }
        if !sessionID.isEmpty   { try visitor.visitSingularStringField(value: sessionID,      fieldNumber: 4) }
        if versionMinor != 0    { try visitor.visitSingularInt32Field(value: versionMinor,    fieldNumber: 5) }
        if versionRevision != 0 { try visitor.visitSingularInt32Field(value: versionRevision, fieldNumber: 6) }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: Ptsl_RequestHeader, rhs: Ptsl_RequestHeader) -> Bool {
        lhs.taskID == rhs.taskID && lhs.command == rhs.command &&
        lhs.version == rhs.version && lhs.sessionID == rhs.sessionID &&
        lhs.versionMinor == rhs.versionMinor && lhs.versionRevision == rhs.versionRevision &&
        lhs.unknownFields == rhs.unknownFields
    }
}

struct Ptsl_Request: SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName = "ptsl.Request"

    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "header"),
        2: .same(proto: "request_body_json"),
    ]

    var header:          Ptsl_RequestHeader = Ptsl_RequestHeader()
    var requestBodyJson: String             = ""
    var unknownFields    = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let f = try decoder.nextFieldNumber() {
            switch f {
            case 1:
                var v: Ptsl_RequestHeader? = nil
                try decoder.decodeSingularMessageField(value: &v)
                if let v { header = v }
            case 2: try decoder.decodeSingularStringField(value: &requestBodyJson)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        try visitor.visitSingularMessageField(value: header, fieldNumber: 1)
        if !requestBodyJson.isEmpty { try visitor.visitSingularStringField(value: requestBodyJson, fieldNumber: 2) }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: Ptsl_Request, rhs: Ptsl_Request) -> Bool {
        lhs.header == rhs.header && lhs.requestBodyJson == rhs.requestBodyJson &&
        lhs.unknownFields == rhs.unknownFields
    }
}

struct Ptsl_ResponseHeader: SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName = "ptsl.ResponseHeader"

    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "task_id"),
        2: .same(proto: "command"),
        3: .same(proto: "status"),
        4: .same(proto: "progress"),
    ]

    var taskID:   String           = ""
    var command:  Ptsl_CommandId   = .cidNone
    var status:   Ptsl_TaskStatus  = .tstatusQueued
    var progress: Int32            = 0
    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let f = try decoder.nextFieldNumber() {
            switch f {
            case 1: try decoder.decodeSingularStringField(value: &taskID)
            case 2: try decoder.decodeSingularEnumField(value: &command)
            case 3: try decoder.decodeSingularEnumField(value: &status)
            case 4: try decoder.decodeSingularInt32Field(value: &progress)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !taskID.isEmpty          { try visitor.visitSingularStringField(value: taskID,  fieldNumber: 1) }
        if command != .cidNone      { try visitor.visitSingularEnumField(value: command,   fieldNumber: 2) }
        if status != .tstatusQueued { try visitor.visitSingularEnumField(value: status,    fieldNumber: 3) }
        if progress != 0            { try visitor.visitSingularInt32Field(value: progress, fieldNumber: 4) }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: Ptsl_ResponseHeader, rhs: Ptsl_ResponseHeader) -> Bool {
        lhs.taskID == rhs.taskID && lhs.command == rhs.command &&
        lhs.status == rhs.status && lhs.progress == rhs.progress &&
        lhs.unknownFields == rhs.unknownFields
    }
}

struct Ptsl_Response: SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
    static let protoMessageName = "ptsl.Response"

    static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
        1: .same(proto: "header"),
        2: .same(proto: "response_body_json"),
        3: .same(proto: "response_error_json"),
    ]

    var header:            Ptsl_ResponseHeader = Ptsl_ResponseHeader()
    var responseBodyJson:  String              = ""
    var responseErrorJson: String              = ""
    var unknownFields      = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let f = try decoder.nextFieldNumber() {
            switch f {
            case 1:
                var v: Ptsl_ResponseHeader? = nil
                try decoder.decodeSingularMessageField(value: &v)
                if let v { header = v }
            case 2: try decoder.decodeSingularStringField(value: &responseBodyJson)
            case 3: try decoder.decodeSingularStringField(value: &responseErrorJson)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        try visitor.visitSingularMessageField(value: header, fieldNumber: 1)
        if !responseBodyJson.isEmpty  { try visitor.visitSingularStringField(value: responseBodyJson,  fieldNumber: 2) }
        if !responseErrorJson.isEmpty { try visitor.visitSingularStringField(value: responseErrorJson, fieldNumber: 3) }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: Ptsl_Response, rhs: Ptsl_Response) -> Bool {
        lhs.header == rhs.header &&
        lhs.responseBodyJson == rhs.responseBodyJson &&
        lhs.responseErrorJson == rhs.responseErrorJson &&
        lhs.unknownFields == rhs.unknownFields
    }
}
