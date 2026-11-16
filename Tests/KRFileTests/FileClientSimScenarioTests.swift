//
//  FileClientSimScenarioTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Testing
import KRCore
import KRSim
import KRWire
@testable import KRFile

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileClientSimScenarioTests {
    private static func payloads(_ frames: [[UInt8]]) -> [[UInt8]] {
        frames.compactMap { frame in
            if case .request(let request)? = try? SysExFrame.parse(frame) {
                return request.payload
            }
            return nil
        }
    }
    
    private static func connected(
        idleReinit: Duration = .seconds(5)
    ) async throws -> (client: FileClient, transport: SimTransport) {
        let pair = SimHarness.make(configuration: SimHarness.configuration(idleReinit: idleReinit))
        try await pair.client.connect()
        return pair
    }
    
    @Test func sampleLifecycleRunsCleanOnTheSim() async throws {
        let (client, transport) = try await Self.connected()
        let data = SimHarness.bytes(count: 5000, seed: 9)
        #expect(try await client.list(node: 1000).isEmpty)
        try await client.write(fid: 1, parent: 1000, name: "001.pcm", flags: .sound, data: data)
        #expect(try await client.stat(fid: 1).size == 5000)
        #expect(try await client.list(node: 1000).map(\.id) == [1])
        #expect(try await client.read(fid: 1).data == data)
        try await client.setMetadata(fid: 1, json: "{\"name\":\"kick\"}")
        #expect(try await client.metadata(fid: 1, key: "name") == "{\"name\":\"kick\"}")
        try await client.play(fid: 1)
        #expect(await transport.device.playedFIDs == [1])
        try await client.delete(fid: 1)
        #expect(try await client.list(node: 1000).isEmpty)
        #expect(await transport.device.isLooping == false)
        #expect(await client.isHalted == false)
        #expect(await client.transferInterrupted == false)
    }
    
    @Test func projectArchiveRoundTrips() async throws {
        let (client, _) = try await Self.connected()
        let data = SimHarness.bytes(count: 6000, seed: 3)
        try await client.write(fid: 3000, parent: 2000, name: "01", flags: .projectArchive, data: data)
        let content = try await client.read(fid: 3000)
        #expect(content.data == data)
        #expect(content.flags == FileCreateFlags.projectArchive.rawValue)
    }
    
    @Test func idleReinitRunsBeforeTheNextCommand() async throws {
        let (client, transport) = try await Self.connected(idleReinit: .milliseconds(300))
        let data = SimHarness.bytes(count: 100, seed: 4)
        try await client.write(fid: 56, parent: 1000, name: "056.pcm", flags: .sound, data: data)
        try await Task.sleep(for: .milliseconds(600))
        let before = await transport.sentFrames.count
        let content = try await client.read(fid: 56)
        let sent = Self.payloads(Array(await transport.sentFrames.dropFirst(before)))
        #expect(content.data == data)
        #expect(sent.count >= 2)
        #expect(sent.first?.first == 0x01)
        #expect(sent.dropFirst().first?.starts(with: [0x03, 0x00]) == true)
    }
    
    @Test func reconnectsAfterADebugLoop() async throws {
        let (client, transport) = try await Self.connected()
        await transport.enterDebugLoop(text: "err pattern 187 2_5_1")
        await #expect(throws: KRError.self) { _ = try await client.stat(fid: 1000) }
        #expect(await client.isHalted)
        await client.disconnect()
        await transport.powerCycle()
        try await client.connect()
        #expect(await client.isHalted == false)
        #expect(try await client.stat(fid: 1000).fid == 1000)
    }
}
