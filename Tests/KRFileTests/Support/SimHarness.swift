//
//  SimHarness.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Foundation
import KRFile
import KRSim
import KRTransport

enum SimHarness {
    static func configuration(idleReinit: Duration = .seconds(5)) -> FileClientConfiguration {
        FileClientConfiguration(
            requestTimeout: .milliseconds(150),
            debugGrace: .milliseconds(500),
            drainWindow: .milliseconds(50),
            haltedPreflight: .milliseconds(300),
            idleReinit: idleReinit,
            pageDelay: .milliseconds(1),
            commitDelay: .milliseconds(10),
            mutationPreflight: .milliseconds(300)
        )
    }
    
    /// Deterministic pseudo-random bytes (LCG, fixed seed).
    static func bytes(count: Int, seed: UInt32 = 1) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 16)
        }
    }
    
    static func make(
        nodes: [SimNode] = [],
        chunkSize: UInt32 = 512,
        configuration: FileClientConfiguration = SimHarness.configuration(),
        interruptedTransfer: Bool = false,
        onInterruptedTransferChange: (@Sendable (Bool) -> Void)? = nil
    ) -> (client: FileClient, transport: SimTransport) {
        var fileSystem = SimFileSystem()
        for node in nodes {
            fileSystem.insert(node)
        }
        let transport = SimTransport(
            device: SimDevice(fileSystem: fileSystem, chunkSize: chunkSize),
            debugPeriod: .milliseconds(100)
        )
        let client = FileClient(
            transport: transport,
            product: .ep133,
            configuration: configuration,
            interruptedTransfer: interruptedTransfer,
            onInterruptedTransferChange: onInterruptedTransferChange
        )
        return (client, transport)
    }
}

/// Collects values from `@Sendable` synchronous callbacks.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    
    init(_ value: Value) {
        stored = value
    }
    
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    
    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}
