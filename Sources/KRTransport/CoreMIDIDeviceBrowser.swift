//
//  CoreMIDIDeviceBrowser.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import CoreMIDI
import KRCore

public final class CoreMIDIDeviceBrowser: Sendable {
    private let client: CoreMIDIClient
    
    public init() async throws(KRError) {
        client = try await CoreMIDIClient.shared()
    }
    
    public func devices() -> [MIDIDeviceEndpoint] {
        Self.currentDevices()
    }
    
    public func deviceUpdates() -> AsyncStream<[MIDIDeviceEndpoint]> {
        let changes = client.changes()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(Self.currentDevices())
            let task = Task {
                for await _ in changes {
                    continuation.yield(Self.currentDevices())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    private static func currentDevices() -> [MIDIDeviceEndpoint] {
        EndpointMatcher.pair(
            sources: CoreMIDIClient.sources().compactMap { CoreMIDIClient.candidate(for: $0) },
            destinations: CoreMIDIClient.destinations().compactMap { CoreMIDIClient.candidate(for: $0) }
        )
    }
}
