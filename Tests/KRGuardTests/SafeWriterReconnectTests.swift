//
//  SafeWriterReconnectTests.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
import Testing
import KRCore
import KRSim
import KRWire
@testable import KRFile
@testable import KRGuard
@_spi(UnsafeDeviceLab) import KRFile

/// Restore and rollback receive the generation read before the write began. These tests really
/// disconnect and reconnect the client and hand the stale generation in, as a reconnect between two steps would.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SafeWriterReconnectTests {
    private struct Counts: Equatable {
        var puts = 0
        var deletes = 0
        var metadataSets = 0
    }
    
    private func counts(_ harness: GuardHarness) async -> Counts {
        var result = Counts()
        for payload in await harness.writeFrames() {
            if payload.first == 0x02 {
                result.puts += 1
            } else if payload.first == 0x06 {
                result.deletes += 1
            } else {
                result.metadataSets += 1
            }
        }
        return result
    }
    
    /// Reads the generation, then re-establishes the connection.
    private func reconnect(_ harness: GuardHarness) async throws -> UInt64 {
        let generation = await harness.client.connectionGeneration
        await harness.client.disconnect()
        try await harness.client.connect()
        #expect(await harness.client.connectionGeneration != generation)
        return generation
    }
    
    private func checkpointOfSlot(
        _ harness: GuardHarness,
        slot: UInt16,
        parts: [String]? = nil,
        metadataJSON: String? = nil
    ) async throws -> Checkpoint {
        let stat = try await harness.client.stat(fid: slot)
        let json = try await harness.client.metadata(fid: slot)
        let data = try await harness.client.read(fid: slot).data
        let restoreParts = try parts ?? #require(MetadataJSON(parsing: json)?.removing(keys: ["crc"]).split(maxBytes: 400))
        let checkpoint = Checkpoint(
            fid: slot,
            operation: .delete,
            prior: .init(
                nodeName: stat.name,
                flags: stat.flags,
                size: stat.size,
                data: Data(data),
                metadataJSON: metadataJSON ?? json
            ),
            restoreMetadataParts: restoreParts
        )
        try await harness.store.save(checkpoint)
        return checkpoint
    }
    
    private func expectUnknownRollback(
        _ error: SafeWriteError?,
        _ harness: GuardHarness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))", sourceLocation: sourceLocation)
            return
        }
        #expect(record.step == .rollback, sourceLocation: sourceLocation)
        #expect(record.reason == "connection re-established", sourceLocation: sourceLocation)
        #expect(saved, sourceLocation: sourceLocation)
        #expect(await harness.store.pending == record, sourceLocation: sourceLocation)
        await expectLaterWritesRefused(harness, sourceLocation: sourceLocation)
    }
    
    private func expectLaterWritesRefused(_ harness: GuardHarness, sourceLocation: SourceLocation = #_sourceLocation) async {
        let before = await counts(harness)
        do throws(SafeWriteError) {
            try await harness.writer.put(
                slot: 6,
                data: GuardHarness.pcm(count: 64, seed: 9),
                metadata: SampleMetadata(name: "kick", channels: 1)
            )
            Issue.record("expected the write to be refused", sourceLocation: sourceLocation)
        } catch {
            guard case .refused(let reason, _) = error else {
                Issue.record("expected refused, got \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(reason == .pendingRecovery, sourceLocation: sourceLocation)
        }
        #expect(await counts(harness) == before, sourceLocation: sourceLocation)
    }
    
    private func expectUnknownRestore(
        _ outcome: RestoreOutcome,
        _ harness: GuardHarness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        guard case .unknown(let error) = outcome else {
            Issue.record("expected unknown, got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        await expectUnknownRollback(error, harness, sourceLocation: sourceLocation)
    }
    
    /// Slot 5 holds other bytes and another node name than the checkpoint.
    private func diverge(_ harness: GuardHarness, slot: UInt16) async throws {
        let stat = try await harness.client.stat(fid: slot)
        try await harness.client.delete(fid: slot)
        try await harness.client.write(
            fid: slot,
            parent: FileNode.soundsID,
            name: "other.pcm",
            flags: FileCreateFlags(rawValue: stat.flags),
            data: GuardHarness.pcm(count: 30, seed: 77)
        )
    }
    
    // MARK: - restoreSlot
    
    @Test func restoreSlotStopsAfterTheRollbackDeleteWhenTheConnectionChanged() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        let checkpoint = try await checkpointOfSlot(harness, slot: 5)
        try await diverge(harness, slot: 5)
        let generation = try await reconnect(harness)
        let before = await counts(harness)
        
        let outcome = await harness.writer.restoreSlot(from: checkpoint, generation: generation)
        
        await expectUnknownRestore(outcome, harness)
        let after = await counts(harness)
        #expect(after.deletes == before.deletes + 1)
        #expect(after.puts == before.puts)
        #expect(after.metadataSets == before.metadataSets)
        await harness.client.disconnect()
    }
    
    @Test func restoreSlotSendsNoWriteWhenTheConnectionChangedBeforeThePut() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        let checkpoint = try await checkpointOfSlot(harness, slot: 5)
        try await harness.client.delete(fid: 5)
        let generation = try await reconnect(harness)
        let before = await counts(harness)
        
        let outcome = await harness.writer.restoreSlot(from: checkpoint, generation: generation)
        
        await expectUnknownRestore(outcome, harness)
        #expect(await counts(harness) == before)
        await harness.client.disconnect()
    }
    
    @Test func restoreSlotStopsBeforeTheFirstMetadataPartWhenTheConnectionChanged() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        let checkpoint = try await checkpointOfSlot(harness, slot: 5)
        try await harness.client.setMetadata(fid: 5, json: #"{"name":"changed"}"#)
        let generation = try await reconnect(harness)
        let before = await counts(harness)
        
        let outcome = await harness.writer.restoreSlot(from: checkpoint, generation: generation)
        
        await expectUnknownRestore(outcome, harness)
        #expect(await counts(harness) == before)
        await harness.client.disconnect()
    }
    
    @Test func restoreSlotWithoutMetadataPartsStopsAfterTheLoopWhenTheConnectionChanged() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        let checkpoint = try await checkpointOfSlot(
            harness,
            slot: 5,
            parts: [],
            metadataJSON: #"{"name":"\"restored\""}"#
        )
        let generation = try await reconnect(harness)
        let before = await counts(harness)
        
        let outcome = await harness.writer.restoreSlot(from: checkpoint, generation: generation)
        
        await expectUnknownRestore(outcome, harness)
        #expect(await counts(harness) == before)
        await harness.client.disconnect()
    }
    
    // MARK: - restoreMetadata
    
    @Test func restoreMetadataStopsAfterTheSetWhenTheConnectionChanged() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let request = WriteRequest.setMetadata(slot: 5, json: #"{"name":"snare"}"#)
        let snapshot = try await harness.writer.preflight(request)
        let checkpoint = try await harness.writer.checkpoint(request, snapshot: snapshot, captureData: false)
        try await harness.client.setMetadata(fid: 5, json: #"{"name":"snare"}"#)
        let generation = try await reconnect(harness)
        let before = await counts(harness)
        
        let outcome = await harness.writer.restoreMetadata(from: checkpoint, generation: generation)
        
        await expectUnknownRestore(outcome, harness)
        let after = await counts(harness)
        #expect(after.metadataSets == before.metadataSets + 1)
        #expect(after.puts == before.puts)
        #expect(after.deletes == before.deletes)
        await harness.client.disconnect()
    }
    
    // MARK: - rollbackPut
    
    @Test func rollbackPutStopsAfterTheDeleteWhenTheConnectionChanged() async throws {
        let harness = try await GuardHarness.make()
        let checkpoint = Checkpoint(fid: 5, operation: .put, prior: nil, expectedSize: 64)
        try await harness.store.save(checkpoint)
        try await harness.client.write(
            fid: 5,
            parent: FileNode.soundsID,
            name: "005.pcm",
            flags: .sound,
            data: GuardHarness.pcm(count: 64, seed: 9)
        )
        let generation = try await reconnect(harness)
        let before = await counts(harness)
        
        let error = await harness.writer.rollbackPut(checkpoint, generation: generation, underlying: nil)
        
        await expectUnknownRollback(error, harness)
        let after = await counts(harness)
        #expect(after.deletes == before.deletes + 1)
        #expect(after.puts == before.puts)
        #expect(after.metadataSets == before.metadataSets)
        await harness.client.disconnect()
    }
}
