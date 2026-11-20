//
//  SafeWriterScenarioTests.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
import Testing
import KRCore
import KRSim
@testable import KRFile
@testable import KRGuard

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SafeWriterScenarioTests {
    private static let metadata = SampleMetadata(name: "kick", channels: 1)
    
    private func node(_ harness: GuardHarness, _ slot: UInt16) async -> SimNode? {
        await harness.transport.device.fileSystem.node(slot)
    }
    
    private static func attemptPut(_ writer: SafeWriter, slot: UInt16, data: [UInt8]) async -> Result<Void, SafeWriteError> {
        do throws(SafeWriteError) {
            try await writer.put(slot: slot, data: data, metadata: metadata)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    
    private func expectSuccess(_ result: Result<Void, SafeWriteError>) {
        if case .failure(let error) = result {
            Issue.record("expected success, got \(error)")
        }
    }
    
    // MARK: - Full flow
    
    @Test func putSetMetadataReplaceDeleteRunWithoutDebugFrames() async throws {
        let harness = try await GuardHarness.make()
        let first = GuardHarness.pcm(count: 700, seed: 3)
        let second = GuardHarness.pcm(count: 900, seed: 4)
        try await harness.writer.put(slot: 5, data: first, metadata: Self.metadata)
        #expect(await node(harness, 5)?.data == first)
        try await harness.writer.setMetadata(slot: 5, json: "{\"sound.pan\":-3}")
        #expect(await node(harness, 5)?.metadata["sound.pan"] == "-3")
        try await harness.writer.replace(slot: 5, data: second, metadata: SampleMetadata(name: "snare", channels: 1))
        let replaced = try #require(await node(harness, 5))
        #expect(replaced.data == second)
        #expect(replaced.metadata["name"] == "\"snare\"")
        try await harness.writer.delete(slot: 5)
        #expect(await node(harness, 5) == nil)
        #expect(await !harness.client.isHalted)
        #expect(await !harness.client.transferInterrupted)
        #expect(await harness.store.pending == nil)
        #expect(await harness.writer.pendingInMemory == nil)
        await harness.client.disconnect()
    }
    
    // MARK: - Single write gate
    
    @Test func concurrentPutsRunOneAfterTheOther() async throws {
        let harness = try await GuardHarness.make()
        let writer = harness.writer
        async let first: Void = writer.put(slot: 5, data: GuardHarness.pcm(count: 1500, seed: 1), metadata: Self.metadata)
        async let second: Void = writer.put(slot: 6, data: GuardHarness.pcm(count: 1500, seed: 2), metadata: Self.metadata)
        try await first
        try await second
        let frames = await harness.writeFrames()
        let opens = frames.indices.filter { frames[$0].starts(with: [0x02, 0x00]) }
        let commits = frames.indices.filter { frames[$0].starts(with: [0x07, 0x01]) }
        #expect(opens.count == 2)
        #expect(commits.count == 2)
        #expect(commits[0] < opens[1])
        #expect(await node(harness, 5) != nil)
        #expect(await node(harness, 6) != nil)
        await harness.client.disconnect()
    }
    
    // MARK: - Cancellation (CT-07)
    
    @Test func cancellingTheCallerMidPutStillEndsWithAnOutcome() async throws {
        let harness = try await GuardHarness.make()
        let data = GuardHarness.pcm(count: 6000, seed: 5)
        let writer = harness.writer
        let task = Task { await Self.attemptPut(writer, slot: 5, data: data) }
        await harness.transport.waitForSent(count: 4)
        task.cancel()
        let result = await task.value
        expectSuccess(result)
        #expect(await node(harness, 5)?.data == data)
        #expect(await !harness.client.transferInterrupted)
        await harness.client.disconnect()
    }
    
    @Test func cancellingAQueuedCallerStillRunsTheOperation() async throws {
        let harness = try await GuardHarness.make()
        let writer = harness.writer
        let big = GuardHarness.pcm(count: 6000, seed: 5)
        let small = GuardHarness.pcm(count: 128, seed: 6)
        let running = Task { await Self.attemptPut(writer, slot: 5, data: big) }
        await harness.transport.waitForSent(count: 4)
        let queued = Task { await Self.attemptPut(writer, slot: 6, data: small) }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        let queuedResult = await queued.value
        let runningResult = await running.value
        expectSuccess(runningResult)
        expectSuccess(queuedResult)
        #expect(await node(harness, 6)?.data == small)
        await harness.client.disconnect()
    }
    
    // MARK: - Static checks (FN-GUARD-009)
    
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }
    
    private static func swiftSources(in directory: String) throws -> [(name: String, lines: [String])] {
        let folder = sourcesRoot.appendingPathComponent(directory)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { file in
            (file.lastPathComponent, try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n"))
        }
    }
    
    @Test func fileClientWritesStayBehindTheSPI() throws {
        let sources = try Self.swiftSources(in: "KRFile")
        #expect(!sources.isEmpty)
        for source in sources {
            for (index, line) in source.lines.enumerated() {
                let isWrite = ["public func write", "public func delete", "public func setMetadata"].contains { line.contains($0) }
                guard isWrite else { continue }
                let guarded = line.contains("@_spi(UnsafeDeviceLab)") || (index > 0 && source.lines[index - 1].contains("@_spi(UnsafeDeviceLab)"))
                #expect(guarded, "\(source.name):\(index + 1) exposes a write without the SPI")
            }
        }
    }
    
    @Test func guardSourcesAvoidFileManagerAndCoreMIDI() throws {
        let sources = try Self.swiftSources(in: "KRGuard")
        #expect(!sources.isEmpty)
        for source in sources {
            let text = source.lines.joined(separator: "\n")
            #expect(!text.contains("FileManager"), "\(source.name) uses FileManager")
            #expect(!text.contains("CoreMIDI"), "\(source.name) imports CoreMIDI")
        }
    }
}
