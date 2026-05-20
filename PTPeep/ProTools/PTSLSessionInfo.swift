import Foundation

// MARK: - Pro Tools spot integration
//
// All spotting goes through the Apple Event path (PTAppleEventSpot.swift).
// No PTSL/gRPC is used for spotting.

enum PTSLError: Error {
    case notConnected, noSession, badResponse
    case commandFailed(String)
}

actor PTSLSessionInfo {

    static let shared = PTSLSessionInfo()

    // MARK: - Region spot

    /// Spots every clip in `region` into the currently selected PT track(s) via Apple Events.
    func spotRegion(_ region: PlayRegion) async throws {
        try await spotRegionViaAppleEvent(region)
    }
}
