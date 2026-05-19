// Hand-written Swift gRPC client matching what protoc-gen-grpc-swift generates for
// sdk/PTSL_minimal.proto (package ptsl, service PTSL).
//
// GRPCClient protocol (grpc-swift 1.x) exposes performAsyncUnaryCall and
// makeServerStreamingCall publicly.
// The protocol only requires `channel` and `defaultCallOptions` — no interceptors.

import GRPC
import NIOCore
import SwiftProtobuf

struct Ptsl_PTSLAsyncClient: GRPCClient {
    var channel: GRPCChannel
    var defaultCallOptions: CallOptions

    init(channel: GRPCChannel, defaultCallOptions: CallOptions = CallOptions()) {
        self.channel = channel
        self.defaultCallOptions = defaultCallOptions
    }

    // MARK: - Unary (most commands)

    func sendGrpcRequest(
        _ request: Ptsl_Request,
        callOptions: CallOptions? = nil
    ) async throws -> Ptsl_Response {
        return try await performAsyncUnaryCall(
            path: "/ptsl.PTSL/SendGrpcRequest",
            request: request,
            callOptions: callOptions ?? defaultCallOptions,
            interceptors: []
        )
    }

    // MARK: - Server-streaming (async commands like Import)
    //
    // PT sends one or more responses: Queued → [InProgress →] Completed (or Failed).
    // We collect all of them and return the last one so the caller can check status.
    // The handler and whenComplete callbacks both fire on the same NIO event-loop
    // thread, so no locking is needed.

    func sendGrpcStreamingRequest(
        _ request: Ptsl_Request,
        callOptions: CallOptions? = nil
    ) async throws -> Ptsl_Response {
        return try await withCheckedThrowingContinuation { continuation in
            var lastResponse: Ptsl_Response? = nil

            let call = makeServerStreamingCall(
                path: "/ptsl.PTSL/SendGrpcStreamingRequest",
                request: request,
                callOptions: callOptions ?? defaultCallOptions,
                interceptors: [],
                handler: { response in lastResponse = response }
            )

            call.status.whenComplete { result in
                switch result {
                case .success(let status) where status.isOk:
                    if let resp = lastResponse {
                        continuation.resume(returning: resp)
                    } else {
                        continuation.resume(
                            throwing: PTSLError.commandFailed("Import: no response received from PT")
                        )
                    }
                case .success(let status):
                    continuation.resume(
                        throwing: PTSLError.commandFailed("Import gRPC status: \(status.code)")
                    )
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
