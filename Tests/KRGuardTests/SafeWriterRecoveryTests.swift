//
//  SafeWriterRecoveryTests.swift
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

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SafeWriterRecoveryTests {
    private static let metadata = SampleMetadata(name: "kick", channels: 1)
    
    private func put(_ harness: GuardHarness, slot: UInt16 = 5, data: [UInt8]) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.put(slot: slot, data: data, metadata: Self.metadata, verifyBytes: true)
            return nil
        } catch {
            return error
        }
    }
    
    private func replace(_ harness: GuardHarness, slot: UInt16 = 5, data: [UInt8]) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.replace(slot: slot, data: data, metadata: Self.metadata, verifyBytes: true)
            return nil
        } catch {
            return error
        }
    }
    
    private func resolve(_ harness: GuardHarness, _ resolution: RecoveryResolution) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.resolveRecovery(resolution)
            return nil
        } catch {
            return error
        }
    }
    
    private func node(_ harness: GuardHarness, _ slot: UInt16) async -> SimNode? {
        await harness.transport.device.fileSystem.node(slot)
    }
    
    private func getDataRequests(_ harness: GuardHarness) async -> Int {
        await harness.transport.sentFrames.filter { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame) else { return false }
            return request.payload.starts(with: [0x03, 0x01])
        }.count
    }
    
    /// Stores a checkpoint of the slot as it is now and records it as pending.
    private func pend(_ harness: GuardHarness, slot: UInt16, expectedSize: UInt32? = nil) async throws -> Checkpoint {
        let stat = try await harness.client.stat(fid: slot)
        let json = try await harness.client.metadata(fid: slot)
        let data = try await harness.client.read(fid: slot).data
        let parts = try #require(MetadataJSON(parsing: json)?.removing(keys: ["crc"]).split(maxBytes: 400))
        let checkpoint = Checkpoint(
            fid: slot,
            operation: .delete,
            prior: .init(nodeName: stat.name, flags: stat.flags, size: stat.size, data: Data(data), metadataJSON: json),
            expectedSize: expectedSize,
            restoreMetadataParts: parts
        )
        try await harness.store.save(checkpoint)
        _ = await harness.writer.recordPending(step: .verify, checkpoint: checkpoint, reason: "test")
        return checkpoint
    }
    
    private func powerCycle(_ harness: GuardHarness) async throws {
        await harness.client.disconnect()
        await harness.transport.powerCycle()
        await harness.transport.clearFaults()
        try await harness.client.clearInterruptedTransfer()
        try await harness.client.connect()
    }
    
    /// Replace whose DELETE succeeds, PUT and restore PUT are rejected: the slot is gone and a record points at the old data.
    private func blocked(_ old: SimNode, nodes: [SimNode]? = nil) async throws -> (GuardHarness, PendingRecovery) {
        let harness = try await GuardHarness.make(nodes: nodes ?? [old])
        await harness.transport.inject(.reject(opcode: [0x02, 0x00], reason: "x"), skip: 0, times: 2)
        let error = await replace(harness, data: GuardHarness.pcm(count: 64, seed: 9))
        guard case .verifyFailed(_, _, let pending?)? = error else {
            Issue.record("expected pending, got \(String(describing: error))")
            throw StoreFailure()
        }
        await harness.transport.clearFaults()
        return (harness, pending)
    }
    
    // MARK: - Inspect
    
    @Test func inspectWithoutARecordIsNil() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        #expect(try await harness.writer.inspectRecovery() == nil)
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    @Test func inspectReportsAnAbsentSlotWithoutWriting() async throws {
        let old = GuardHarness.sample(5, count: 120)
        let (harness, pending) = try await blocked(old)
        let frames = await harness.writeFrames().count
        let inspection = try #require(try await harness.writer.inspectRecovery())
        #expect(inspection.record == pending)
        #expect(inspection.checkpoint?.prior?.data == Data(old.data))
        #expect(inspection.current == .absent)
        #expect(await harness.writeFrames().count == frames)
        await harness.client.disconnect()
    }
    
    @Test func inspectReadsDataWhenTheSizeMatchesTheCheckpoint() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        let checkpoint = try await pend(harness, slot: 5)
        let inspection = try #require(try await harness.writer.inspectRecovery())
        guard case .present(let size, _, let data, let json) = inspection.current else {
            Issue.record("expected a present slot")
            return
        }
        #expect(size == 100)
        #expect(data.map { Data($0) } == checkpoint.prior?.data)
        #expect(json != nil)
        await harness.client.disconnect()
    }
    
    @Test func inspectSkipsTheGetWhenTheSizeDiffersFromTheCheckpoint() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        _ = try await pend(harness, slot: 5)
        let before = await getDataRequests(harness)
        let checkpoint = Checkpoint(fid: 5, operation: .put, prior: nil, expectedSize: 777)
        try await harness.store.save(checkpoint)
        _ = await harness.writer.recordPending(step: .put, checkpoint: checkpoint, reason: "test")
        let inspection = try #require(try await harness.writer.inspectRecovery())
        guard case .present(_, _, let data, _) = inspection.current else {
            Issue.record("expected a present slot")
            return
        }
        #expect(data == nil)
        #expect(await getDataRequests(harness) == before)
        await harness.client.disconnect()
    }
    
    @Test func inspectWhileInterruptedReadsNoData() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        let checkpoint = try await pend(harness, slot: 5)
        await harness.client.markTransferInterrupted()
        let before = await getDataRequests(harness)
        let inspection = try #require(try await harness.writer.inspectRecovery())
        guard case .present(let size, _, let data, _) = inspection.current else {
            Issue.record("expected a present slot")
            return
        }
        #expect(size == checkpoint.prior?.size)
        #expect(data == nil)
        #expect(await getDataRequests(harness) == before)
        await harness.client.disconnect()
    }
    
    @Test func inspectDuringATimedOutPutReadsNoData() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 1, times: nil)
        let error = await put(harness, data: GuardHarness.pcm(count: 64))
        guard case .outcomeUnknown(let record, _)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(await harness.client.transferInterrupted)
        let inspection = try #require(try await harness.writer.inspectRecovery())
        #expect(inspection.record == record)
        if case .present(_, _, let data, _) = inspection.current {
            #expect(data == nil)
        }
        #expect(await getDataRequests(harness) == 0)
        await harness.client.disconnect()
    }
    
    @Test func inspectFallsBackToTheStoreAfterARestart() async throws {
        let old = GuardHarness.sample(5, count: 120)
        let (harness, pending) = try await blocked(old)
        let fresh = SafeWriter(client: harness.client, store: harness.store)
        let inspection = try #require(try await fresh.inspectRecovery())
        #expect(inspection.record == pending)
        await harness.client.disconnect()
    }
    
    // MARK: - Resolve keep
    
    @Test func keepWritesNothingAndClearsTheRecord() async throws {
        let (harness, _) = try await blocked(GuardHarness.sample(5, count: 120))
        let frames = await harness.writeFrames().count
        #expect(await resolve(harness, .keep) == nil)
        #expect(await harness.writeFrames().count == frames)
        #expect(await harness.store.pending == nil)
        #expect(await harness.writer.pendingInMemory == nil)
        #expect(await put(harness, slot: 6, data: GuardHarness.pcm(count: 64)) == nil)
        await harness.client.disconnect()
    }
    
    @Test func keepKeepsTheRecordWhenTheStoreCannotClearIt() async throws {
        let (harness, pending) = try await blocked(GuardHarness.sample(5, count: 120))
        await harness.store.setClearPendingError(StoreFailure())
        #expect(await resolve(harness, .keep) == .refused(.checkpointFailed, underlying: nil))
        #expect(await harness.store.pending == pending)
        #expect(await harness.writer.pendingInMemory == pending)
        await harness.client.disconnect()
    }
    
    @Test func resolveWithoutARecordDoesNothing() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        #expect(await resolve(harness, .restore) == nil)
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    // MARK: - Resolve restore
    
    @Test func restoreAfterTheBlockerBringsBackDataAndName() async throws {
        let old = GuardHarness.sample(5, count: 120)
        let (harness, _) = try await blocked(old)
        #expect(await resolve(harness, .restore) == nil)
        let stored = try #require(await node(harness, 5))
        #expect(stored.data == old.data)
        #expect(stored.name == old.name)
        #expect(stored.metadata["name"] == "\"old5\"")
        #expect(await harness.store.pending == nil)
        #expect(await harness.writer.pendingInMemory == nil)
        #expect(await put(harness, slot: 6, data: GuardHarness.pcm(count: 64)) == nil)
        await harness.client.disconnect()
    }
    
    @Test func restoreAfterATimedOutReplaceBringsTheSlotBack() async throws {
        let old = GuardHarness.sample(5, count: 120)
        let harness = try await GuardHarness.make(nodes: [old])
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 1, times: nil)
        let error = await replace(harness, data: GuardHarness.pcm(count: 64, seed: 9))
        guard case .outcomeUnknown(let record, _)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        try await powerCycle(harness)
        #expect(await resolve(harness, .restore) == nil)
        let stored = try #require(await node(harness, 5))
        #expect(stored.data == old.data)
        #expect(stored.metadata["name"] == "\"old5\"")
        #expect(await harness.store.pending == nil)
        let restoreCheckpoint = try #require(await harness.store.checkpoints.last)
        #expect(restoreCheckpoint.operation == .restore)
        #expect(restoreCheckpoint.prior?.data == nil)
        #expect(restoreCheckpoint.id != record.checkpointID)
        await harness.client.disconnect()
    }
    
    @Test func restoreAfterATimedOutPutLeavesAnEmptySlot() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 1, times: nil)
        let error = await put(harness, data: GuardHarness.pcm(count: 64))
        guard case .outcomeUnknown = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        try await powerCycle(harness)
        #expect(await resolve(harness, .restore) == nil)
        #expect(await node(harness, 5) == nil)
        #expect(await harness.store.pending == nil)
        let restoreCheckpoint = try #require(await harness.store.checkpoints.last)
        #expect(restoreCheckpoint.operation == .restore)
        #expect(restoreCheckpoint.prior?.data == nil)
        #expect(await getDataRequests(harness) == 0)
        await harness.client.disconnect()
    }
    
    @Test func restoreOfAMatchingSlotSendsNoWriteFrame() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        _ = try await pend(harness, slot: 5)
        #expect(await resolve(harness, .restore) == nil)
        #expect(await harness.writeFrames().isEmpty)
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test func restoreWhileInterruptedIsRefusedAndKeepsTheRecord() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        let checkpoint = try await pend(harness, slot: 5)
        await harness.client.markTransferInterrupted()
        #expect(await resolve(harness, .restore) == .refused(.transferInterrupted, underlying: nil))
        #expect(await harness.store.pending?.checkpointID == checkpoint.id)
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    @Test func restoreTimingOutAgainKeepsTheOriginalCheckpoint() async throws {
        let old = GuardHarness.sample(5, count: 120)
        let (harness, pending) = try await blocked(old)
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 0, times: nil)
        let error = await resolve(harness, .restore)
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(saved)
        #expect(record.checkpointID == pending.checkpointID)
        #expect(await harness.store.pending?.checkpointID == pending.checkpointID)
        await harness.client.disconnect()
    }
    
    @Test func restoreWithAMissingCheckpointIsRefused() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let ghost = Checkpoint(fid: 5, operation: .delete, prior: nil)
        _ = await harness.writer.recordPending(step: .verify, checkpoint: ghost, reason: "test")
        #expect(await resolve(harness, .restore) == .refused(.checkpointFailed, underlying: nil))
        #expect(await harness.store.pending?.checkpointID == ghost.id)
        await harness.client.disconnect()
    }
    
    // MARK: - Retention
    
    @Test func pruneKeepsTheCheckpointOfAPendingRecovery() async throws {
        let (harness, pending) = try await blocked(GuardHarness.sample(5, count: 120))
        try await harness.store.prune(fid: 5, keep: 0)
        #expect(try await harness.store.load(id: pending.checkpointID) != nil)
        await harness.client.disconnect()
    }
}
