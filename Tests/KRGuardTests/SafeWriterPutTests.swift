//
//  SafeWriterPutTests.swift
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

private actor FrameProbe {
    private(set) var framesAtSave: Int?
    
    func record(_ count: Int) { framesAtSave = count }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SafeWriterPutTests {
    private static let metadata = SampleMetadata(name: "kick", channels: 1)
    
    private func put(
        _ harness: GuardHarness,
        slot: UInt16 = 5,
        data: [UInt8],
        verifyBytes: Bool = true
    ) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            try await harness.writer.put(slot: slot, data: data, metadata: Self.metadata, verifyBytes: verifyBytes)
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
    
    // MARK: - Success
    
    @Test func putWithByteVerifyWritesDataAndFourMetadataKeys() async throws {
        let harness = try await GuardHarness.make()
        let data = GuardHarness.pcm(count: 700)
        #expect(await put(harness, data: data) == nil)
        let stored = try #require(await node(harness, 5))
        #expect(stored.data == data)
        #expect(Set(stored.metadata.keys) == ["samplerate", "channels", "format", "name"])
        #expect(stored.metadata["name"] == "\"kick\"")
        #expect(stored.metadata["format"] == "\"s16\"")
        #expect(await getDataRequests(harness) > 0)
        #expect(await harness.store.checkpoints.count == 1)
        await harness.client.disconnect()
    }
    
    @Test func putWithoutByteVerifyReadsNoData() async throws {
        let harness = try await GuardHarness.make()
        #expect(await put(harness, data: GuardHarness.pcm(count: 700), verifyBytes: false) == nil)
        #expect(await getDataRequests(harness) == 0)
        await harness.client.disconnect()
    }
    
    @Test func checkpointIsSavedBeforeTheFirstWriteFrame() async throws {
        let harness = try await GuardHarness.make()
        let probe = FrameProbe()
        let transport = harness.transport
        await harness.store.setOnSave { _ in
            await probe.record(await transport.sentFrames.filter { frame in
                guard case .request(let request)? = try? SysExFrame.parse(frame) else { return false }
                return request.payload.first == 0x02
            }.count)
        }
        #expect(await put(harness, data: GuardHarness.pcm(count: 64)) == nil)
        #expect(await probe.framesAtSave == 0)
        await harness.client.disconnect()
    }
    
    // MARK: - Unknown outcome
    
    @Test func timeoutDuringPutIsUnknownAndStopsWriting() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 1, times: nil)
        let error = await put(harness, data: GuardHarness.pcm(count: 64))
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .put)
        #expect(saved)
        #expect(await harness.store.pending == record)
        let framesAfterFailure = await harness.writeFrames().count
        let next = await put(harness, slot: 6, data: GuardHarness.pcm(count: 64))
        #expect(next == .refused(.pendingRecovery, underlying: nil))
        #expect(await harness.writer.pendingInMemory == record)
        #expect(await harness.writeFrames().count == framesAfterFailure)
        await harness.client.disconnect()
    }
    
    @Test func unsavedRecordStillBlocksLaterWrites() async throws {
        let harness = try await GuardHarness.make()
        await harness.store.setSavePendingError(StoreFailure())
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 1, times: nil)
        let error = await put(harness, data: GuardHarness.pcm(count: 64))
        guard case .outcomeUnknown(_, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(!saved)
        #expect(await harness.store.pending == nil)
        #expect(await harness.writer.pendingInMemory != nil)
        let next = await put(harness, slot: 6, data: GuardHarness.pcm(count: 64))
        #expect(next == .refused(.pendingRecovery, underlying: nil))
        await harness.client.disconnect()
    }
    
    @Test func debugFrameDuringPutIsUnknown() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.inject(.debugLoop(onOpcode: [0x02, 0x01], text: "err lfs 6327"))
        let error = await put(harness, data: GuardHarness.pcm(count: 64))
        guard case .outcomeUnknown(let record, _)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return
        }
        #expect(record.step == .put)
        await harness.client.disconnect()
    }
    
    // MARK: - Rollback
    
    @Test func corruptedCommitIsRolledBackOnce() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.inject(.corruptCommit)
        let data = GuardHarness.pcm(count: 64)
        let error = await put(harness, data: data)
        guard case .verifyFailed(let rolledBack, _, let pending)? = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(rolledBack)
        #expect(pending == nil)
        #expect(await node(harness, 5) == nil)
        let putFrames = await harness.writeFrames().filter { $0.starts(with: [0x02, 0x00]) }
        #expect(putFrames.count == 1)
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test func rejectedRollbackLeavesPendingRecovery() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.inject(.corruptCommit)
        await harness.transport.inject(.reject(opcode: [0x06], reason: "x"))
        let error = await put(harness, data: GuardHarness.pcm(count: 64))
        guard case .verifyFailed(let rolledBack, _, let pending?)? = error else {
            Issue.record("expected verifyFailed with pending, got \(String(describing: error))")
            return
        }
        #expect(!rolledBack)
        #expect(pending.step == .rollback)
        #expect(await harness.store.pending == pending)
        let next = await put(harness, slot: 6, data: GuardHarness.pcm(count: 64))
        #expect(next == .refused(.pendingRecovery, underlying: nil))
        await harness.client.disconnect()
    }
    
    @Test func cleanlyRejectedOpenLeavesNothingToRecover() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.inject(.reject(opcode: [0x02, 0x00], reason: "full"))
        let error = await put(harness, data: GuardHarness.pcm(count: 64))
        guard case .verifyFailed(let rolledBack, _, let pending)? = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(rolledBack)
        #expect(pending == nil)
        #expect(await node(harness, 5) == nil)
        await harness.client.disconnect()
    }
    
    // MARK: - Retention
    
    @Test func keepsOnlyTheConfiguredNumberOfCheckpoints() async throws {
        let harness = try await GuardHarness.make(writerConfiguration: SafeWriterConfiguration(checkpointsPerSlot: 2))
        for _ in 0..<2 {
            #expect(await put(harness, data: GuardHarness.pcm(count: 64)) == nil)
            try await harness.writer.delete(slot: 5)
        }
        #expect(await put(harness, data: GuardHarness.pcm(count: 64)) == nil)
        #expect(await harness.store.checkpoints.count == 2)
        await harness.client.disconnect()
    }
    
    @Test func pruneFailureDoesNotFailThePut() async throws {
        let harness = try await GuardHarness.make()
        await harness.store.setPruneError(StoreFailure())
        #expect(await put(harness, data: GuardHarness.pcm(count: 64)) == nil)
        await harness.client.disconnect()
    }
}
