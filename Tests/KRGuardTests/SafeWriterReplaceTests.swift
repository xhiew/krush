//
//  SafeWriterReplaceTests.swift
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
struct SafeWriterReplaceTests {
    private static let metadata = SampleMetadata(name: "kick", channels: 1)
    
    private func replace(_ harness: GuardHarness, slot: UInt16 = 5, data: [UInt8]) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.replace(slot: slot, data: data, metadata: Self.metadata, verifyBytes: true)
            return nil
        } catch {
            return error
        }
    }
    
    private func node(_ harness: GuardHarness, _ slot: UInt16) async -> SimNode? {
        await harness.transport.device.fileSystem.node(slot)
    }
    
    // MARK: - Success
    
    @Test(arguments: [false, true])
    func replaceDeletesThenPutsThenSetsMetadata(ghost: Bool) async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 64)], ghostMetadata: ghost)
        let data = GuardHarness.pcm(count: 700, seed: 9)
        #expect(await replace(harness, data: data) == nil)
        let frames = await harness.writeFrames()
        #expect(frames.first?.first == 0x06)
        #expect(frames.dropFirst().first?.starts(with: [0x02, 0x00]) == true)
        #expect(frames.last?.starts(with: [0x07, 0x01]) == true)
        #expect(frames.filter { $0.first == 0x06 }.count == 1)
        let stored = try #require(await node(harness, 5))
        #expect(stored.data == data)
        #expect(stored.metadata["name"] == "\"kick\"")
        await harness.client.disconnect()
    }
    
    @Test func replaceOfAnEmptySlotIsRefused() async throws {
        let harness = try await GuardHarness.make()
        #expect(await replace(harness, data: GuardHarness.pcm(count: 64)) == .refused(.slotEmpty, underlying: nil))
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    // MARK: - Rollback
    
    @Test func mismatchRestoresOldDataAndName() async throws {
        let old = GuardHarness.sample(5, count: 200)
        let harness = try await GuardHarness.make(nodes: [old])
        await harness.transport.inject(.corruptCommit, skip: 0, times: 1)
        let error = await replace(harness, data: GuardHarness.pcm(count: 700, seed: 9))
        guard case .verifyFailed(let rolledBack, _, let pending)? = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(rolledBack)
        #expect(pending == nil)
        let stored = try #require(await node(harness, 5))
        #expect(stored.data == old.data)
        #expect(stored.name == old.name)
        #expect(stored.metadata["name"] == "\"old5\"")
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test func cleanlyRejectedDeleteSendsNoFurtherWrite() async throws {
        let old = GuardHarness.sample(5)
        let harness = try await GuardHarness.make(nodes: [old])
        await harness.transport.inject(.reject(opcode: [0x06], reason: "x"), skip: 0, times: 1)
        let error = await replace(harness, data: GuardHarness.pcm(count: 64, seed: 9))
        guard case .verifyFailed(let rolledBack, _, let pending)? = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(rolledBack)
        #expect(pending == nil)
        #expect(await harness.writeFrames().count == 1)
        #expect(await node(harness, 5)?.data == old.data)
        await harness.client.disconnect()
    }
    
    @Test func rejectedPutAndRejectedRestoreLeaveARecoverableCheckpoint() async throws {
        let old = GuardHarness.sample(5, count: 120)
        let harness = try await GuardHarness.make(nodes: [old])
        await harness.transport.inject(.reject(opcode: [0x02, 0x00], reason: "x"), skip: 0, times: 2)
        let error = await replace(harness, data: GuardHarness.pcm(count: 64, seed: 9))
        guard case .verifyFailed(let rolledBack, _, let pending?)? = error else {
            Issue.record("expected verifyFailed with pending, got \(String(describing: error))")
            return
        }
        #expect(!rolledBack)
        #expect(await harness.store.pending == pending)
        let checkpoint = try #require(await harness.store.load(id: pending.checkpointID))
        #expect(checkpoint.prior?.data == Data(old.data))
        #expect(await node(harness, 5) == nil)
        let next = await replace(harness, slot: 6, data: GuardHarness.pcm(count: 64))
        #expect(next == .refused(.pendingRecovery, underlying: nil))
        await harness.client.disconnect()
    }
    
    @Test func largeOldMetadataIsRestoredInSeveralSets() async throws {
        var metadata = ["name": "\"old5\"", "samplerate": "46875", "channels": "1", "format": "\"s16\"", "crc": "123"]
        for index in 0..<24 {
            metadata[String(format: "sound.k%02d", index)] = "\"" + String(repeating: "v", count: 30) + "\""
        }
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, metadata: metadata)])
        await harness.transport.inject(.corruptCommit, skip: 0, times: 1)
        let error = await replace(harness, data: GuardHarness.pcm(count: 64, seed: 9))
        guard case .verifyFailed(let rolledBack, _, _)? = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(rolledBack)
        let checkpoint = try #require(await harness.store.checkpoints.first)
        let parts = try #require(checkpoint.restoreMetadataParts)
        let limit = await harness.client.maxMetadataJSONBytes
        #expect(parts.count >= 3)
        #expect(parts.allSatisfy { $0.utf8.count <= limit })
        let stored = try #require(await node(harness, 5))
        for (key, value) in metadata where key != "crc" {
            #expect(stored.metadata[key] == value)
        }
        await harness.client.disconnect()
    }
    
    // MARK: - Unknown outcome
    
    @Test func timeoutDuringPutIsUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 1, times: nil)
        let error = await replace(harness, data: GuardHarness.pcm(count: 64, seed: 9))
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .put)
        #expect(saved)
        await harness.client.disconnect()
    }
    
    @Test func timeoutDuringRollbackIsUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let original = GuardHarness.pcm(count: 64, seed: 9)
        await harness.transport.inject(.corruptCommit, skip: 0, times: 1)
        await harness.transport.inject(
            .silence(opcode: [0x02, 0x01]),
            skip: GuardHarness.putFrameCount(dataCount: original.count),
            times: nil
        )
        let error = await replace(harness, data: original)
        guard case .outcomeUnknown(let record, _)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .rollback)
        #expect(await harness.store.pending == record)
        await harness.client.disconnect()
    }
}
