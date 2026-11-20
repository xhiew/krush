//
//  GuardHarness.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
@testable import KRFile
import KRSim
import KRWire
@testable import KRGuard

struct GuardHarness {
    let client: FileClient
    let transport: SimTransport
    let store: InMemoryCheckpointStore
    let writer: SafeWriter
    
    static func configuration() -> FileClientConfiguration {
        FileClientConfiguration(
            requestTimeout: .milliseconds(150),
            debugGrace: .milliseconds(100),
            drainWindow: .milliseconds(50),
            haltedPreflight: .milliseconds(300),
            transferTimeout: .milliseconds(150),
            deleteTimeout: .milliseconds(150),
            pageDelay: .milliseconds(1),
            commitDelay: .milliseconds(10),
            mutationPreflight: .milliseconds(300)
        )
    }
    
    /// Deterministic pseudo-random PCM bytes (LCG, fixed seed).
    static func pcm(count: Int, seed: UInt32 = 1) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 16)
        }
    }
    
    static func sample(_ slot: UInt16, count: Int = 64, name: String? = nil, metadata: [String: String]? = nil) -> SimNode {
        var node = SimFileSystem.sample(slot: slot, pcm: pcm(count: count, seed: UInt32(slot)))
        node.metadata = metadata ?? [
            "name": "\"old\(slot)\"",
            "samplerate": "46875",
            "channels": "1",
            "format": "\"s16\"",
            "crc": "123"
        ]
        if let name {
            node.metadata["name"] = "\"\(name)\""
        }
        return node
    }
    
    static func make(
        nodes: [SimNode] = [],
        ghostMetadata: Bool = false,
        chunkSize: UInt32 = 512,
        writerConfiguration: SafeWriterConfiguration = .init(),
        connected: Bool = true,
        interruptedTransfer: Bool = false
    ) async throws -> GuardHarness {
        var fileSystem = SimFileSystem()
        for node in nodes {
            fileSystem.insert(node)
        }
        let transport = SimTransport(
            device: SimDevice(fileSystem: fileSystem, chunkSize: chunkSize, ghostMetadata: ghostMetadata),
            debugPeriod: .milliseconds(100)
        )
        let client = FileClient(
            transport: transport,
            product: .ep133,
            configuration: configuration(),
            interruptedTransfer: interruptedTransfer
        )
        if connected {
            try await client.connect()
        }
        let store = InMemoryCheckpointStore()
        let writer = SafeWriter(client: client, store: store, configuration: writerConfiguration)
        return GuardHarness(client: client, transport: transport, store: store, writer: writer)
    }
    
    /// Payloads of the requests that change the device: PUT pages, DELETE and metadata set.
    func writeFrames() async -> [[UInt8]] {
        await transport.sentFrames.compactMap { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame) else { return nil }
            let payload = request.payload
            let isWrite = payload.first == 0x02 || payload.first == 0x06 || payload.starts(with: [0x07, 0x01])
            return isWrite ? payload : nil
        }
    }
    
    /// Data pages plus the EOF page of one PUT.
    static func putFrameCount(dataCount: Int, chunk: Int = 512) -> Int {
        let perPage = FileCodec.putPayloadBytes(chunkSize: chunk)
        return (dataCount + perPage - 1) / perPage + 1
    }
}
