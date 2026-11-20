//
//  SafeWriterMetadataTests.swift
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
struct SafeWriterMetadataTests {
    private func setMetadata(_ harness: GuardHarness, _ json: String) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.setMetadata(slot: 5, json: json)
            return nil
        } catch {
            return error
        }
    }
    
    private func node(_ harness: GuardHarness) async -> SimNode? {
        await harness.transport.device.fileSystem.node(5)
    }
    
    private func restore(_ harness: GuardHarness, _ checkpoint: Checkpoint) async -> RestoreOutcome {
        await harness.writer.restoreMetadata(from: checkpoint, generation: await harness.client.connectionGeneration)
    }
    
    @Test func nameChangeReadsBack() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        #expect(await setMetadata(harness, "{\"name\":\"snare\"}") == nil)
        #expect(await node(harness)?.metadata["name"] == "\"snare\"")
        #expect(await harness.store.checkpoints.first?.writtenKeys == ["name"])
        await harness.client.disconnect()
    }
    
    @Test func newKeyIsMergedAndOldKeysSurvive() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        #expect(await setMetadata(harness, "{\"sound.pan\":-3}") == nil)
        let stored = try #require(await node(harness))
        #expect(stored.metadata["sound.pan"] == "-3")
        #expect(stored.metadata["name"] == "\"old5\"")
        await harness.client.disconnect()
    }
    
    @Test func readOnlyKeyIsRefusedWithoutWriting() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        #expect(await setMetadata(harness, "{\"format\":\"s8\"}") == .refused(.readOnlyKey, underlying: nil))
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    @Test func ackWithoutEffectIsRolledBackWithoutWriting() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await harness.transport.inject(.ackWithoutEffect(opcode: [0x07, 0x01]), skip: 0, times: 1)
        let error = await setMetadata(harness, "{\"name\":\"snare\"}")
        guard case .verifyFailed(let rolledBack, _, let pending)? = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(rolledBack)
        #expect(pending == nil)
        #expect(await harness.writeFrames().count == 1)
        #expect(await node(harness)?.metadata["name"] == "\"old5\"")
        await harness.client.disconnect()
    }
    
    @Test func timeoutOnSetIsUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await harness.transport.inject(.silence(opcode: [0x07, 0x01]))
        let error = await setMetadata(harness, "{\"name\":\"snare\"}")
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .metadataSet)
        #expect(saved)
        #expect(await harness.store.pending == record)
        await harness.client.disconnect()
    }
    
    @Test func restoreKeepsNewKeysAndReportsNoPendingRecovery() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        #expect(await setMetadata(harness, "{\"sound.pan\":-3}") == nil)
        let checkpoint = try #require(await harness.store.checkpoints.first)
        let outcome = await restore(harness, checkpoint)
        guard case .extraKeysRemain = outcome else {
            Issue.record("expected extraKeysRemain, got \(outcome)")
            return
        }
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test func restoreRewritesPriorValuesOfChangedKeys() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        #expect(await setMetadata(harness, "{\"name\":\"snare\"}") == nil)
        let checkpoint = try #require(await harness.store.checkpoints.first)
        let outcome = await restore(harness, checkpoint)
        guard case .restored = outcome else {
            Issue.record("expected restored, got \(outcome)")
            return
        }
        #expect(await node(harness)?.metadata["name"] == "\"old5\"")
        await harness.client.disconnect()
    }
    
    @Test func restoreThatCannotWriteLeavesPendingRecovery() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        #expect(await setMetadata(harness, "{\"name\":\"snare\"}") == nil)
        let checkpoint = try #require(await harness.store.checkpoints.first)
        await harness.transport.inject(.reject(opcode: [0x07, 0x01], reason: "x"))
        let outcome = await restore(harness, checkpoint)
        guard case .notRestored(let record) = outcome else {
            Issue.record("expected notRestored, got \(outcome)")
            return
        }
        #expect(record.checkpointID == checkpoint.id)
        #expect(await harness.store.pending == record)
        await harness.client.disconnect()
    }
}
