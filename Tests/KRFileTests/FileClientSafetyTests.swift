//
//  FileClientSafetyTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Testing
import KRCore
import KRSim
import KRWire
@testable import KRFile
@_spi(UnsafeDeviceLab) import KRFile

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileClientSafetyTests {
    private static func error(of operation: () async throws -> Void) async -> KRError? {
        do {
            try await operation()
            return nil
        } catch {
            return error as? KRError
        }
    }
    
    private static func sample(_ slot: UInt16, count: Int) -> SimNode {
        SimFileSystem.sample(slot: slot, pcm: SimHarness.bytes(count: count, seed: UInt32(slot)))
    }
    
    private static func make(
        nodes: [SimNode] = [],
        configuration: FileClientConfiguration = SimHarness.configuration(),
        replyDelay: Duration = .zero,
        debugPeriod: Duration = .milliseconds(100)
    ) -> (client: FileClient, transport: SimTransport) {
        var fileSystem = SimFileSystem()
        for node in nodes {
            fileSystem.insert(node)
        }
        let transport = SimTransport(
            device: SimDevice(fileSystem: fileSystem),
            replyDelay: replyDelay,
            debugPeriod: debugPeriod
        )
        return (FileClient(transport: transport, product: .ep133, configuration: configuration), transport)
    }
    
    // MARK: - Rolling preflight
    
    @Test func preflightRollsFromSessionStart() async throws {
        let (client, _) = Self.make(nodes: [Self.sample(1, count: 4), Self.sample(2, count: 4)])
        let start = ContinuousClock.now
        try await client.connect()
        try await client.delete(fid: 1)
        #expect(ContinuousClock.now - start >= .milliseconds(240))
        try await Task.sleep(for: .milliseconds(400))
        let second = ContinuousClock.now
        try await client.delete(fid: 2)
        #expect(ContinuousClock.now - second < .milliseconds(200))
    }
    
    @Test func preflightCatchesALoopStartedAfterConnect() async throws {
        var configuration = SimHarness.configuration()
        configuration.mutationPreflight = .milliseconds(500)
        let (client, transport) = Self.make(configuration: configuration, debugPeriod: .milliseconds(200))
        try await client.connect()
        await transport.enterDebugLoop(text: "err pattern 187 2_5_1")
        let before = await transport.sentFrames.count
        let failure = await Self.error {
            try await client.write(fid: 5, parent: 1000, name: "005.pcm", flags: .sound, data: [1, 2])
        }
        guard case .deviceDebugFrame? = failure else {
            Issue.record("expected deviceDebugFrame, got \(String(describing: failure))")
            return
        }
        #expect(await transport.sentFrames.count == before)
        await client.disconnect()
    }
    
    // MARK: - Lock after an abandoned GET
    
    private static func abandonedRead() async throws -> (client: FileClient, transport: SimTransport) {
        var configuration = SimHarness.configuration()
        configuration.pageDelay = .seconds(5)
        let pair = Self.make(nodes: [Self.sample(5, count: 1000)], configuration: configuration)
        try await pair.client.connect()
        let task = Task { try await pair.client.read(fid: 5) }
        await pair.transport.waitForSent(count: 3)
        task.cancel()
        #expect(await Self.error { _ = try await task.value } == .cancelled)
        return pair
    }
    
    @Test func lockBlocksEveryCommandThatCouldBreakTheDevice() async throws {
        let (client, transport) = try await Self.abandonedRead()
        let before = await transport.sentFrames.count
        let blocked: [() async throws -> Void] = [
            { try await client.write(fid: 6, parent: 1000, name: "006.pcm", flags: .sound, data: [1]) },
            { try await client.delete(fid: 5) },
            { try await client.setMetadata(fid: 5, json: "{\"a\":1}") },
            { _ = try await client.read(fid: 5) },
            { try await client.play(fid: 5) }
        ]
        for operation in blocked {
            #expect(await Self.error(of: operation) == .transferInterrupted)
        }
        #expect(await transport.sentFrames.count == before)
        #expect(await transport.device.isLooping == false)
        #expect(try await client.stat(fid: 5).fid == 5)
        #expect(try await client.list(node: 1000).count == 1)
        #expect(try await client.metadata(fid: 5) == "{}")
    }
    
    @Test func lockClearsAfterPowerCycle() async throws {
        let (client, transport) = try await Self.abandonedRead()
        await client.disconnect()
        await transport.powerCycle()
        try await client.clearInterruptedTransfer()
        try await client.connect()
        try await client.write(fid: 6, parent: 1000, name: "006.pcm", flags: .sound, data: [1, 2, 3])
        #expect(try await client.read(fid: 6).data == [1, 2, 3])
    }
    
    // MARK: - Debug and ordering
    
    @Test func debugLoopMidPutHaltsAndLocks() async throws {
        let (client, transport) = Self.make()
        try await client.connect()
        await transport.inject(.debugLoop(onOpcode: [0x02, 0x01], text: "err pattern 213 2_5_1"))
        let failure = await Self.error {
            try await client.write(fid: 6, parent: 1000, name: "006.pcm", flags: .sound, data: [1, 2, 3])
        }
        guard case .deviceDebugFrame? = failure else {
            Issue.record("expected deviceDebugFrame, got \(String(describing: failure))")
            return
        }
        #expect(await client.isHalted)
        #expect(await client.transferInterrupted == true)
        let before = await transport.sentFrames.count
        _ = await Self.error { _ = try await client.stat(fid: 6) }
        _ = await Self.error { try await client.delete(fid: 6) }
        #expect(await transport.sentFrames.count == before)
        await client.disconnect()
    }
    
    @Test func overlappingCommandsNeverOverlapOnTheDevice() async throws {
        let (client, transport) = Self.make(nodes: [Self.sample(1, count: 4)], replyDelay: .milliseconds(20))
        try await client.connect()
        let writing = Task {
            try await client.write(
                fid: 6, parent: 1000, name: "006.pcm", flags: .sound, data: SimHarness.bytes(count: 4330)
            )
        }
        // Connect INIT, write INIT, then the PUT open: the write now owns the gate.
        await transport.waitForSent(count: 3)
        let stating = Task { try await client.stat(fid: 1) }
        let listing = Task { try await client.list(node: 1000) }
        try await writing.value
        _ = try await stating.value
        _ = try await listing.value
        #expect(await transport.device.isLooping == false)
        var payloads: [[UInt8]] = []
        for frame in await transport.sentFrames {
            if case .request(let request)? = try? SysExFrame.parse(frame) {
                payloads.append(request.payload)
            }
        }
        let lastPage = payloads.lastIndex { $0.starts(with: [0x02, 0x01]) }
        let stat = payloads.firstIndex { $0.first == 0x0B }
        let list = payloads.firstIndex { $0.first == 0x04 }
        #expect(lastPage != nil && stat != nil && list != nil)
        #expect(lastPage! < stat! && lastPage! < list!)
        await client.disconnect()
    }
}
