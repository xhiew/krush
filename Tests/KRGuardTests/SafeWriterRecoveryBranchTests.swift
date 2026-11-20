//
//  SafeWriterRecoveryBranchTests.swift
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

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SafeWriterRecoveryBranchTests {
    private func resolve(_ harness: GuardHarness, _ resolution: RecoveryResolution) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.resolveRecovery(resolution)
            return nil
        } catch {
            return error
        }
    }
    
    private func inspect(_ harness: GuardHarness) async -> Result<RecoveryInspection?, SafeWriteError> {
        do throws(SafeWriteError) {
            return .success(try await harness.writer.inspectRecovery())
        } catch {
            return .failure(error)
        }
    }
    
    private func put(_ harness: GuardHarness, slot: UInt16 = 5) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.put(
                slot: slot,
                data: GuardHarness.pcm(count: 64, seed: 9),
                metadata: SampleMetadata(name: "kick", channels: 1)
            )
            return nil
        } catch {
            return error
        }
    }
    
    private func delete(_ harness: GuardHarness) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.delete(slot: 5)
            return nil
        } catch {
            return error
        }
    }
    
    /// Pending record for a put that supposedly went into a slot that was empty.
    private func pendEmptySlot(_ harness: GuardHarness) async throws -> PendingRecovery {
        let checkpoint = Checkpoint(fid: 5, operation: .put, prior: nil, expectedSize: 64)
        try await harness.store.save(checkpoint)
        return await harness.writer.recordPending(step: .put, checkpoint: checkpoint, reason: "test").record
    }
    
    /// Checkpoint of slot 5 as it is now, recorded as the reference of a pending delete.
    private func pendCurrent(_ harness: GuardHarness) async throws -> PendingRecovery {
        let stat = try await harness.client.stat(fid: 5)
        let json = try await harness.client.metadata(fid: 5)
        let data = try await harness.client.read(fid: 5).data
        let parts = try #require(MetadataJSON(parsing: json)?.removing(keys: ["crc"]).split(maxBytes: 400))
        let checkpoint = Checkpoint(
            fid: 5,
            operation: .delete,
            prior: .init(nodeName: stat.name, flags: stat.flags, size: stat.size, data: Data(data), metadataJSON: json),
            restoreMetadataParts: parts
        )
        try await harness.store.save(checkpoint)
        return await harness.writer.recordPending(step: .verify, checkpoint: checkpoint, reason: "test").record
    }
    
    private func expectRefused(_ error: SafeWriteError?, _ reason: SafeWriteRefusal, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .refused(let actual, _)? = error else {
            Issue.record("expected refused(\(reason)), got \(String(describing: error))", sourceLocation: sourceLocation)
            return
        }
        #expect(actual == reason, sourceLocation: sourceLocation)
    }
    
    // MARK: - #10 restoring a slot that was empty
    
    @Test func restoreDeletesWhatEmptySlotCheckpointRecorded() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        _ = try await pendEmptySlot(harness)
        #expect(await resolve(harness, .restore) == nil)
        #expect(await harness.transport.device.fileSystem.node(5) == nil)
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test func restoreOfAlreadyEmptySlotWritesNothing() async throws {
        let harness = try await GuardHarness.make()
        _ = try await pendEmptySlot(harness)
        #expect(await resolve(harness, .restore) == nil)
        #expect(await harness.writeFrames().isEmpty)
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test(arguments: [
        SimFault.reject(opcode: [0x06], reason: "busy"),
        SimFault.ackWithoutEffect(opcode: [0x06])
    ])
    func emptySlotRestoreThatCannotDeleteStaysPending(fault: SimFault) async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        _ = try await pendEmptySlot(harness)
        await harness.transport.inject(fault, skip: 0, times: nil)
        let error = await resolve(harness, .restore)
        guard case .verifyFailed(let rolledBack, _, let pending?)? = error else {
            Issue.record("expected pending verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(!rolledBack)
        #expect(pending.step == .rollback)
        #expect(await harness.store.pending == pending)
        #expect(await harness.transport.device.fileSystem.node(5) != nil)
        await harness.client.disconnect()
    }
    
    @Test func emptySlotRestoreDeleteTimeoutIsUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        _ = try await pendEmptySlot(harness)
        await harness.transport.inject(.silence(opcode: [0x06]), skip: 0, times: nil)
        let error = await resolve(harness, .restore)
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .rollback)
        #expect(saved)
        #expect(await harness.store.pending == record)
        await harness.client.disconnect()
    }
    
    @Test func emptySlotRestoreWithUnreadableSlotIsUnknownAndDeletesNothing() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        _ = try await pendEmptySlot(harness)
        await harness.transport.inject(.silence(opcode: [0x04]), skip: 2, times: 1)
        let error = await resolve(harness, .restore)
        guard case .outcomeUnknown(let record, _)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .rollback)
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    @Test func emptySlotRestoreWithUnreadableVerifyIsUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        _ = try await pendEmptySlot(harness)
        await harness.transport.inject(.silence(opcode: [0x04]), skip: 3, times: 1)
        let error = await resolve(harness, .restore)
        guard case .outcomeUnknown(let record, _)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .rollback)
        #expect(await harness.store.pending == record)
        await harness.client.disconnect()
    }
    
    // MARK: - #10 restoring a metadata set
    
    @Test func restoreOfAMetadataSetPutsPriorValuesBack() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let request = WriteRequest.setMetadata(slot: 5, json: #"{"name":"snare"}"#)
        let snapshot = try await harness.writer.preflight(request)
        let checkpoint = try await harness.writer.checkpoint(request, snapshot: snapshot, captureData: false)
        try await harness.client.setMetadata(fid: 5, json: #"{"name":"snare"}"#)
        _ = await harness.writer.recordPending(step: .verify, checkpoint: checkpoint, reason: "test")
        
        #expect(await resolve(harness, .restore) == nil)
        
        let stored = try #require(await harness.transport.device.fileSystem.node(5))
        #expect(stored.metadata["name"] == "\"old5\"")
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    // MARK: - #10 inspection read errors
    
    @Test(arguments: [[UInt8]([0x04]), [0x0B]])
    func inspectMapsListAndStatTimeoutsToPreflightFailed(opcode: [UInt8]) async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        _ = try await pendCurrent(harness)
        await harness.transport.inject(.silence(opcode: opcode), skip: 0, times: nil)
        let result = await inspect(harness)
        guard case .failure(let error) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        expectRefused(error, .preflightFailed)
        await harness.client.disconnect()
    }
    
    @Test func inspectMapsAListDebugFrameToDebugLoop() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        _ = try await pendCurrent(harness)
        await harness.transport.inject(.debugLoop(onOpcode: [0x04], text: "x"), skip: 0, times: nil)
        let result = await inspect(harness)
        guard case .failure(let error) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        expectRefused(error, .debugLoop)
        await harness.client.disconnect()
    }
    
    // MARK: - #10 store failures
    
    @Test func unreadablePendingStateFailsInspectAndResolve() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let record = PendingRecovery(checkpointID: UUID(), fid: 5, operation: .put, step: .put, reason: "t")
        try await harness.store.savePendingRecovery(record)
        await harness.store.setPendingError(StoreFailure())
        
        let inspected = await inspect(harness)
        guard case .failure(let inspectError) = inspected else {
            Issue.record("expected failure, got \(inspected)")
            return
        }
        expectRefused(inspectError, .checkpointFailed)
        expectRefused(await resolve(harness, .keep), .checkpointFailed)
        await harness.client.disconnect()
    }
    
    @Test func unloadableCheckpointFailsInspectAndRestoreButNotKeep() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let record = try await pendCurrent(harness)
        await harness.store.setLoadError(StoreFailure())
        
        let inspected = await inspect(harness)
        guard case .failure(let inspectError) = inspected else {
            Issue.record("expected failure, got \(inspected)")
            return
        }
        expectRefused(inspectError, .checkpointFailed)
        expectRefused(await resolve(harness, .restore), .checkpointFailed)
        #expect(await harness.store.pending == record)
        #expect(await resolve(harness, .keep) == nil)
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test func restoreWithAMissingCheckpointRefusesAndKeepsTheRecord() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let record = PendingRecovery(checkpointID: UUID(), fid: 5, operation: .delete, step: .verify, reason: "t")
        try await harness.store.savePendingRecovery(record)
        expectRefused(await resolve(harness, .restore), .checkpointFailed)
        #expect(await harness.store.pending == record)
        await harness.client.disconnect()
    }
    
    @Test func clearFailureAfterKeepKeepsTheRecord() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let record = try await pendCurrent(harness)
        await harness.store.setClearPendingError(StoreFailure())
        expectRefused(await resolve(harness, .keep), .checkpointFailed)
        #expect(await harness.store.pending == record)
        await harness.client.disconnect()
    }
    
    @Test func clearFailureAfterRestoreKeepsTheRecordButTheSlotIsRestored() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let record = try await pendCurrent(harness)
        try await harness.client.setMetadata(fid: 5, json: #"{"name":"changed"}"#)
        await harness.store.setClearPendingError(StoreFailure())
        
        expectRefused(await resolve(harness, .restore), .checkpointFailed)
        
        #expect(await harness.store.pending == record)
        #expect(await harness.transport.device.fileSystem.node(5)?.metadata["name"] == "\"old5\"")
        await harness.client.disconnect()
    }
    
    // MARK: - #3 an unsaved pending record is reported as unknown
    
    @Test(arguments: [
        SimFault.ackWithoutEffect(opcode: [0x06]),
        SimFault.reject(opcode: [0x06], reason: "busy")
    ])
    func rollbackIncompleteWithUnsavedRecordIsOutcomeUnknown(fault: SimFault) async throws {
        let harness = try await GuardHarness.make()
        await harness.store.setSavePendingError(StoreFailure())
        await harness.transport.inject(.corruptCommit, skip: 0, times: 1)
        await harness.transport.inject(fault, skip: 0, times: nil)
        
        let error = await put(harness)
        
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(!saved)
        #expect(record.step == .rollback)
        #expect(await harness.store.pending == nil)
        #expect(await harness.writer.pendingInMemory == record)
        expectRefused(await put(harness, slot: 6), .pendingRecovery)
        await harness.client.disconnect()
    }
    
    @Test func emptySlotRecoveryPendingWithUnsavedRecordIsOutcomeUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        _ = try await pendEmptySlot(harness)
        await harness.store.setSavePendingError(StoreFailure())
        await harness.transport.inject(.reject(opcode: [0x06], reason: "busy"), skip: 0, times: nil)
        
        let error = await resolve(harness, .restore)
        
        guard case .outcomeUnknown(_, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(!saved)
        #expect(await harness.writer.pendingInMemory != nil)
        await harness.client.disconnect()
    }
    
    @Test func deleteNotAppliedWithUnsavedRecordIsOutcomeUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 64)])
        let client = harness.client
        // The slot changes after the checkpoint was taken, so it no longer matches it when the delete is rejected.
        await harness.store.setOnSave { _ in
            try? await client.delete(fid: 5)
            try? await client.write(
                fid: 5,
                parent: FileNode.soundsID,
                name: "other.pcm",
                flags: .sound,
                data: GuardHarness.pcm(count: 64, seed: 77)
            )
        }
        await harness.store.setSavePendingError(StoreFailure())
        await harness.transport.inject(.reject(opcode: [0x06], reason: "busy"), skip: 1, times: 1)
        
        let error = await delete(harness)
        
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(!saved)
        #expect(await harness.writer.pendingInMemory == record)
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    // MARK: - #9 retention keeps the checkpoint a pending record references
    
    @Test func writerNeverPrunesWhilePendingAndPrunesAfterItIsCleared() async throws {
        let harness = try await GuardHarness.make(
            nodes: [GuardHarness.sample(5, count: 64)],
            writerConfiguration: SafeWriterConfiguration(checkpointsPerSlot: 1)
        )
        try await harness.writer.setMetadata(slot: 5, json: #"{"name":"first"}"#)
        await harness.transport.inject(.silence(opcode: [0x06]), skip: 0, times: 1)
        let failure = await delete(harness)
        guard case .outcomeUnknown(let record, _)? = failure else {
            Issue.record("expected outcomeUnknown, got \(String(describing: failure))")
            return
        }
        let pendingSince = await harness.store.events.count
        
        expectRefused(await put(harness, slot: 6), .pendingRecovery)
        _ = await inspect(harness)
        #expect(try await harness.store.load(id: record.checkpointID) != nil)
        let during = await harness.store.events.dropFirst(pendingSince)
        #expect(!during.contains(.prune(fid: 5, keep: 1)))
        
        #expect(await resolve(harness, .restore) == nil)
        try await harness.writer.setMetadata(slot: 5, json: #"{"name":"last"}"#)
        
        #expect(await harness.store.events.contains(.prune(fid: 5, keep: 1)))
        #expect(try await harness.store.load(id: record.checkpointID) == nil)
        #expect(await harness.store.checkpoints.count == 1)
        await harness.client.disconnect()
    }
}
