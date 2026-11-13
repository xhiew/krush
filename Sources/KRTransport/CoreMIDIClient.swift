//
//  CoreMIDIClient.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import CoreMIDI
import Foundation
import KRCore
import os

final class CoreMIDIClient: Sendable {
    private static let cache = OSAllocatedUnfairLock<CoreMIDIClient?>(initialState: nil)
    
    private struct SignalState {
        var nextID = 0
        var continuations: [Int: AsyncStream<Void>.Continuation] = [:]
    }
    
    private let ref: MIDIClientRef
    private let signals: OSAllocatedUnfairLock<SignalState>
    
    private init(ref: MIDIClientRef, signals: OSAllocatedUnfairLock<SignalState>) {
        self.ref = ref
        self.signals = signals
    }
    
    var clientRef: MIDIClientRef { ref }
    
    /// Failures are not cached, so a later call retries.
    static func shared() async throws(KRError) -> CoreMIDIClient {
        if let existing = cache.withLock({ $0 }) {
            return existing
        }
        // CoreMIDI delivers notifications on the run loop of the creating thread.
        let created = try await MainActor.run { () -> Result<CoreMIDIClient, KRError> in
            do throws(KRError) {
                return .success(try create())
            } catch {
                return .failure(error)
            }
        }.get()
        let winner = cache.withLock { cached -> CoreMIDIClient in
            if let existing = cached {
                return existing
            }
            cached = created
            return created
        }
        if winner !== created {
            MIDIClientDispose(created.ref)
        }
        return winner
    }
    
    /// Emits whenever the MIDI setup, an endpoint or one of its properties changes.
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = signals.withLock { state -> Int in
                state.nextID += 1
                state.continuations[state.nextID] = continuation
                return state.nextID
            }
            continuation.onTermination = { [signals] _ in
                signals.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }
    
    private static func create() throws(KRError) -> CoreMIDIClient {
        let signals = OSAllocatedUnfairLock(initialState: SignalState())
        var ref = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("KRTransport" as CFString, &ref) { notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                let targets = signals.withLock { Array($0.continuations.values) }
                for target in targets {
                    target.yield()
                }
            default:
                break
            }
        }
        try check(status, "MIDIClientCreateWithBlock")
        return CoreMIDIClient(ref: ref, signals: signals)
    }
}

extension CoreMIDIClient {
    static func check(_ status: OSStatus, _ operation: String) throws(KRError) {
        guard status == noErr else {
            throw .transportFailure(operation: operation, status: status)
        }
    }
    
    static func sources() -> [MIDIEndpointRef] {
        (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
    }
    
    static func destinations() -> [MIDIEndpointRef] {
        (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
    }
    
    static func integerProperty(_ object: MIDIObjectRef, _ key: CFString) -> Int32? {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(object, key, &value) == noErr else { return nil }
        return value
    }
    
    static func stringProperty(_ object: MIDIObjectRef, _ key: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    
    static func isOffline(_ object: MIDIObjectRef) -> Bool {
        integerProperty(object, kMIDIPropertyOffline) == 1
    }
    
    static func candidate(for endpoint: MIDIEndpointRef) -> EndpointCandidate? {
        guard let uniqueID = integerProperty(endpoint, kMIDIPropertyUniqueID) else { return nil }
        var entity = MIDIEntityRef()
        var entityID: Int32?
        var deviceID: Int32?
        if MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0 {
            entityID = integerProperty(entity, kMIDIPropertyUniqueID)
            var device = MIDIDeviceRef()
            if MIDIEntityGetDevice(entity, &device) == noErr, device != 0 {
                deviceID = integerProperty(device, kMIDIPropertyUniqueID)
            }
        }
        return EndpointCandidate(
            uniqueID: uniqueID,
            name: stringProperty(endpoint, kMIDIPropertyDisplayName) ?? "",
            entityID: entityID,
            deviceID: deviceID,
            isOffline: isOffline(endpoint)
        )
    }
    
    /// Nil when the endpoint is unknown, offline or missing from the current enumeration.
    static func liveEndpoint(uniqueID: Int32, among endpoints: [MIDIEndpointRef]) -> MIDIEndpointRef? {
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(uniqueID, &object, &type) == noErr,
              object != 0,
              endpoints.contains(object),
              !isOffline(object)
        else { return nil }
        return object
    }
}
