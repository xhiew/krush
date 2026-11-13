//
//  CoreMIDITransport.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import CoreMIDI
import KRCore
import os

public final class CoreMIDITransport: Transport {
    private static let streamBufferSize = 256
    
    private struct State {
        var nextToken: UInt64 = 0
        var generation: UInt64 = 0
        var continuation: AsyncStream<[UInt8]>.Continuation?
        var decoder = UMPSysEx7.Decoder()
        var inputPort = MIDIPortRef()
        var outputPort = MIDIPortRef()
        var source = MIDIEndpointRef()
        var destination = MIDIEndpointRef()
        var watcher: Task<Void, Never>?
    }
    
    private let endpoint: MIDIDeviceEndpoint
    private let state = OSAllocatedUnfairLock(initialState: State())
    
    public init(endpoint: MIDIDeviceEndpoint) {
        self.endpoint = endpoint
    }
    
    deinit {
        teardown()
    }
    
    public func connect() async throws(KRError) -> AsyncStream<[UInt8]> {
        guard state.withLock({ $0.continuation == nil }) else { throw .alreadyConnected }
        let client = try await CoreMIDIClient.shared()
        let changes = client.changes()
        guard let source = CoreMIDIClient.liveEndpoint(
                  uniqueID: endpoint.sourceID,
                  among: CoreMIDIClient.sources()
              ),
              let destination = CoreMIDIClient.liveEndpoint(
                  uniqueID: endpoint.destinationID,
                  among: CoreMIDIClient.destinations()
              )
        else { throw .deviceNotFound }
        
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.streamBufferSize)
        )
        let state = state
        let token = state.withLock { current -> UInt64 in
            current.nextToken += 1
            return current.nextToken
        }
        continuation.onTermination = { [weak self] _ in self?.teardown(ifGeneration: token) }
        var inputPort = MIDIPortRef()
        try CoreMIDIClient.check(
            MIDIInputPortCreateWithProtocol(client.clientRef, "KRTransport In" as CFString, ._1_0, &inputPort) { list, _ in
                let words = Self.copyWords(from: list)
                state.withLock { current in
                    guard let continuation = current.continuation else { return }
                    for frame in current.decoder.feed(words: words) {
                        continuation.yield(frame)
                    }
                }
            },
            "MIDIInputPortCreateWithProtocol"
        )
        var outputPort = MIDIPortRef()
        let outputStatus = MIDIOutputPortCreate(client.clientRef, "KRTransport Out" as CFString, &outputPort)
        guard outputStatus == noErr else {
            MIDIPortDispose(inputPort)
            throw .transportFailure(operation: "MIDIOutputPortCreate", status: outputStatus)
        }
        
        let watcher = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                if !self.isEndpointAvailable(), self.teardown(ifGeneration: token) {
                    return
                }
            }
        }
        let (input, output) = (inputPort, outputPort)
        let claimed = state.withLock { current -> Bool in
            guard current.continuation == nil else { return false }
            current = State(
                nextToken: current.nextToken,
                generation: token,
                continuation: continuation,
                inputPort: input,
                outputPort: output,
                source: source,
                destination: destination,
                watcher: watcher
            )
            return true
        }
        guard claimed else {
            watcher.cancel()
            MIDIPortDispose(inputPort)
            MIDIPortDispose(outputPort)
            throw .alreadyConnected
        }
        
        let connectStatus = MIDIPortConnectSource(inputPort, source, nil)
        guard connectStatus == noErr else {
            guard teardown(ifGeneration: token) else { throw .deviceNotFound }
            throw .transportFailure(operation: "MIDIPortConnectSource", status: connectStatus)
        }
        // The watcher ignores unplugs that happen before the claim, so re-check once here.
        guard isEndpointAvailable() else {
            teardown(ifGeneration: token)
            throw .deviceNotFound
        }
        return stream
    }
    
    public func send(_ frame: [UInt8]) async throws(KRError) {
        let target = state.withLock { current in
            current.continuation == nil ? nil : (port: current.outputPort, destination: current.destination)
        }
        guard let target else { throw .disconnected }
        let words = try UMPSysEx7.encode(frame: frame)
        do {
            try MIDIEventListWriter.send(words: words, port: target.port, destination: target.destination)
        } catch {
            if state.withLock({ $0.continuation == nil }) { throw .disconnected }
            throw error
        }
    }
    
    public func disconnect() async {
        teardown()
    }
    
    /// Returns false when nothing was torn down (already gone, or the connection belongs to another generation).
    @discardableResult
    private func teardown(ifGeneration generation: UInt64? = nil) -> Bool {
        let old = state.withLock { current -> State? in
            if let generation, current.generation != generation { return nil }
            let old = current
            current = State(nextToken: old.nextToken)
            return old
        }
        guard let old, let continuation = old.continuation else { return false }
        old.watcher?.cancel()
        MIDIPortDisconnectSource(old.inputPort, old.source)
        MIDIPortDispose(old.inputPort)
        MIDIPortDispose(old.outputPort)
        continuation.finish()
        return true
    }
    
    private func isEndpointAvailable() -> Bool {
        CoreMIDIClient.liveEndpoint(uniqueID: endpoint.sourceID, among: CoreMIDIClient.sources()) != nil
            && CoreMIDIClient.liveEndpoint(uniqueID: endpoint.destinationID, among: CoreMIDIClient.destinations()) != nil
    }
    
    static func copyWords(from list: UnsafePointer<MIDIEventList>) -> [UInt32] {
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) ?? 12
        var words: [UInt32] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let start = UnsafeRawPointer(packet).advanced(by: wordsOffset)
            words.append(contentsOf: UnsafeBufferPointer(start: start.assumingMemoryBound(to: UInt32.self), count: count))
        }
        return words
    }
}
