//
//  SafeWriterDeleteTests.swift
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
struct SafeWriterDeleteTests {
    private func delete(_ harness: GuardHarness, slot: UInt16 = 5) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.delete(slot: slot)
            return nil
        } catch {
            return error
        }
    }
    
    private func node(_ harness: GuardHarness, _ slot: UInt16) async -> SimNode? {
        await harness.transport.device.fileSystem.node(slot)
    }
    
    @Test func deleteRemovesTheSlotAndKeepsABackup() async throws {
        let sample = GuardHarness.sample(5, count: 300)
        let harness = try await GuardHarness.make(nodes: [sample])
        #expect(await delete(harness) == nil)
        #expect(await node(harness, 5) == nil)
        let checkpoint = try #require(await harness.store.checkpoints.first)
        #expect(checkpoint.operation == .delete)
        #expect(checkpoint.prior?.data == Data(sample.data))
        await harness.client.disconnect()
    }
    
    @Test func deleteAckedWithoutEffectLeavesNothingPendingButKeepsCheckpoint() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await harness.transport.inject(.ackWithoutEffect(opcode: [0x06]))
        let error = await delete(harness)
        guard case .verifyFailed(let rolledBack, _, let pending)? = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(!rolledBack)
        #expect(pending == nil)
        #expect(await harness.store.checkpoints.count == 1)
        #expect(await harness.store.pending == nil)
        #expect(await node(harness, 5) != nil)
        await harness.client.disconnect()
    }
    
    @Test func rejectedDeleteOfIntactSlotLeavesNothingPending() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await harness.transport.inject(.reject(opcode: [0x06], reason: "busy"))
        let error = await delete(harness)
        guard case .verifyFailed(let rolledBack, _, let pending)? = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(!rolledBack)
        #expect(pending == nil)
        await harness.client.disconnect()
    }
    
    @Test func timeoutDuringDeleteIsUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await harness.transport.inject(.silence(opcode: [0x06]))
        let error = await delete(harness)
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .delete)
        #expect(saved)
        let next = await delete(harness)
        #expect(next == .refused(.pendingRecovery, underlying: nil))
        await harness.client.disconnect()
    }
    
    @Test func ghostMetadataDoesNotFailDeleteVerify() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)], ghostMetadata: true)
        #expect(await delete(harness) == nil)
        #expect(await node(harness, 5) == nil)
        await harness.client.disconnect()
    }
    
    @Test func pruneFailureDoesNotFailTheDelete() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await harness.store.setPruneError(StoreFailure())
        #expect(await delete(harness) == nil)
        await harness.client.disconnect()
    }
}
