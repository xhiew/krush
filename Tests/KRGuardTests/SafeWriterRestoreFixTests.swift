//
//  SafeWriterRestoreFixTests.swift
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
struct SafeWriterRestoreFixTests {
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
    
    /// Checkpoint of the slot as it is now, recorded as pending.
    private func pend(_ harness: GuardHarness, slot: UInt16) async throws -> Checkpoint {
        let stat = try await harness.client.stat(fid: slot)
        let json = try await harness.client.metadata(fid: slot)
        let data = try await harness.client.read(fid: slot).data
        let parts = try #require(MetadataJSON(parsing: json)?.removing(keys: ["crc"]).split(maxBytes: 400))
        let checkpoint = Checkpoint(
            fid: slot,
            operation: .delete,
            prior: .init(nodeName: stat.name, flags: stat.flags, size: stat.size, data: Data(data), metadataJSON: json),
            restoreMetadataParts: parts
        )
        try await harness.store.save(checkpoint)
        _ = await harness.writer.recordPending(step: .verify, checkpoint: checkpoint, reason: "test")
        return checkpoint
    }
    
    /// Replaces the slot with other bytes and another node name.
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
    
    private func putOpenCount(_ harness: GuardHarness) async -> Int {
        await harness.transport.sentFrames.filter { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame) else { return false }
            return request.payload.starts(with: [0x02, 0x00])
        }.count
    }
    
    // MARK: - #1 metadata verified when the data matches
    
    @Test func restoreOfMatchingDataStillRestoresDifferingMetadata() async throws {
        let old = GuardHarness.sample(5, count: 100)
        let harness = try await GuardHarness.make(nodes: [old])
        _ = try await pend(harness, slot: 5)
        try await harness.client.setMetadata(fid: 5, json: "{\"name\":\"changed\"}")
        
        #expect(await resolve(harness, .restore) == nil)
        
        let stored = try #require(await harness.transport.device.fileSystem.node(5))
        #expect(stored.metadata["name"] == "\"old5\"")
        #expect(stored.data == old.data)
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test func restoreOfMatchingDataAndMetadataWritesNothing() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        _ = try await pend(harness, slot: 5)
        #expect(await resolve(harness, .restore) == nil)
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    // MARK: - #2 rollback delete verified before the PUT
    
    @Test func restoreDoesNotPutWhenTheRollbackDeleteHadNoEffect() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        _ = try await pend(harness, slot: 5)
        try await diverge(harness, slot: 5)
        let opens = await putOpenCount(harness)
        await harness.transport.inject(.ackWithoutEffect(opcode: [0x06]), skip: 0, times: nil)
        
        let error = await resolve(harness, .restore)
        
        guard case .verifyFailed(let rolledBack, _, let pending?)? = error else {
            Issue.record("expected pending verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(!rolledBack)
        #expect(await putOpenCount(harness) == opens)
        #expect(await harness.store.pending == pending)
        await harness.client.disconnect()
    }
    
    // MARK: - #3 unsaved record is reported as unknown
    
    @Test func unsavedPendingRecordOnRestoreFailureIsOutcomeUnknown() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        _ = try await pend(harness, slot: 5)
        try await diverge(harness, slot: 5)
        await harness.transport.inject(.ackWithoutEffect(opcode: [0x06]), skip: 0, times: nil)
        await harness.store.setSavePendingError(StoreFailure())
        
        let error = await resolve(harness, .restore)
        
        guard case .outcomeUnknown(_, let recordSaved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(!recordSaved)
        #expect(await harness.writer.pendingInMemory != nil)
        await harness.client.disconnect()
    }
    
    // MARK: - #4 inspection does not hide read failures
    
    @Test func inspectMapsAMetadataDebugFrameToDebugLoop() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        _ = try await pend(harness, slot: 5)
        await harness.transport.inject(.debugLoop(onOpcode: [0x07, 0x02], text: "x"), skip: 0, times: nil)
        
        let result = await inspect(harness)
        
        guard case .failure(let error) = result, case .refused(.debugLoop, _) = error else {
            Issue.record("expected refused(.debugLoop), got \(result)")
            return
        }
        await harness.client.disconnect()
    }
    
    @Test func inspectMapsAMetadataTimeoutToPreflightFailed() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        _ = try await pend(harness, slot: 5)
        await harness.transport.inject(.silence(opcode: [0x07, 0x02]), skip: 0, times: nil)
        
        let result = await inspect(harness)
        
        guard case .failure(let error) = result, case .refused(.preflightFailed, let underlying) = error else {
            Issue.record("expected refused(.preflightFailed), got \(result)")
            return
        }
        #expect(underlying != nil)
        await harness.client.disconnect()
    }
    
    @Test func inspectMapsAGetTimeoutToPreflightFailed() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5, count: 100)])
        _ = try await pend(harness, slot: 5)
        await harness.transport.inject(.silence(opcode: [0x03, 0x01]), skip: 0, times: nil)
        
        let result = await inspect(harness)
        
        guard case .failure(let error) = result, case .refused(.preflightFailed, _) = error else {
            Issue.record("expected refused(.preflightFailed), got \(result)")
            return
        }
        await harness.client.disconnect()
    }
}
