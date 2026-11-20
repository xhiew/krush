//
//  SafeWriterPublicPathTests.swift
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

enum WriteOp: CaseIterable, Sendable {
    case put
    case replace
    case delete
    case setMetadata
}

struct WriteCounts: Equatable {
    var open = 0
    var page = 0
    var delete = 0
    var metaSet = 0
}

private actor CountProbe {
    private(set) var counts: WriteCounts?
    
    func record(_ counts: WriteCounts) { self.counts = counts }
}

private func writeCounts(_ transport: SimTransport) async -> WriteCounts {
    var counts = WriteCounts()
    for frame in await transport.sentFrames {
        guard case .request(let request)? = try? SysExFrame.parse(frame) else { continue }
        let payload = request.payload
        if payload.starts(with: [0x02, 0x00]) {
            counts.open += 1
        } else if payload.starts(with: [0x02, 0x01]) {
            counts.page += 1
        } else if payload.first == 0x06 {
            counts.delete += 1
        } else if payload.starts(with: [0x07, 0x01]) {
            counts.metaSet += 1
        }
    }
    return counts
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SafeWriterPublicPathTests {
    private static let sample = GuardHarness.sample(5, count: 64)
    
    private func harness(
        _ op: WriteOp,
        connected: Bool = true,
        interrupted: Bool = false,
        ghost: Bool = false
    ) async throws -> GuardHarness {
        try await GuardHarness.make(
            nodes: op == .put ? [] : [Self.sample],
            ghostMetadata: ghost,
            connected: connected,
            interruptedTransfer: interrupted
        )
    }
    
    private func call(
        _ op: WriteOp,
        _ harness: GuardHarness,
        slot: UInt16 = 5,
        name: String = "kick",
        data: [UInt8] = GuardHarness.pcm(count: 64, seed: 9),
        json: String = #"{"name":"snare"}"#
    ) async -> SafeWriteError? {
        let metadata = SampleMetadata(name: name, channels: 1)
        do throws(SafeWriteError) {
            switch op {
            case .put:
                try await harness.writer.put(slot: slot, data: data, metadata: metadata)
            case .replace:
                try await harness.writer.replace(slot: slot, data: data, metadata: metadata)
            case .delete:
                try await harness.writer.delete(slot: slot)
            case .setMetadata:
                try await harness.writer.setMetadata(slot: slot, json: json)
            }
            return nil
        } catch {
            return error
        }
    }
    
    private func reason(_ error: SafeWriteError?) -> SafeWriteRefusal? {
        guard case .refused(let reason, _)? = error else { return nil }
        return reason
    }
    
    private func expectRefused(
        _ op: WriteOp,
        _ expected: SafeWriteRefusal,
        _ harness: GuardHarness,
        slot: UInt16 = 5,
        name: String = "kick",
        data: [UInt8] = GuardHarness.pcm(count: 64, seed: 9),
        json: String = #"{"name":"snare"}"#,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let error = await call(op, harness, slot: slot, name: name, data: data, json: json)
        #expect(reason(error) == expected, "\(op): got \(String(describing: error))", sourceLocation: sourceLocation)
        #expect(await writeCounts(harness.transport) == WriteCounts(), "\(op) wrote", sourceLocation: sourceLocation)
    }
    
    private func expectBlocked(
        _ harness: GuardHarness,
        _ record: PendingRecovery,
        refusal: SafeWriteRefusal = .pendingRecovery
    ) async {
        #expect(await harness.store.pending == record)
        #expect(await harness.writer.pendingInMemory == record)
        let before = await writeCounts(harness.transport)
        for op in WriteOp.allCases {
            let error = await call(op, harness, slot: op == .put ? 6 : 5)
            #expect(reason(error) == refusal, "\(op): got \(String(describing: error))")
        }
        #expect(await writeCounts(harness.transport) == before)
    }
    
    private func expectUnknown(_ error: SafeWriteError?, step: WriteStep) -> PendingRecovery? {
        guard case .outcomeUnknown(let record, let saved)? = error else {
            Issue.record("expected outcomeUnknown, got \(String(describing: error))")
            return nil
        }
        #expect(record.step == step)
        #expect(saved)
        return record
    }
    
    // MARK: - #6 refusals through the public API
    
    @Test(arguments: WriteOp.allCases)
    func notConnectedRefusesAndWritesNothing(op: WriteOp) async throws {
        let harness = try await harness(op, connected: false)
        await expectRefused(op, .notConnected, harness)
    }
    
    @Test(arguments: WriteOp.allCases)
    func debugLoopRefusesThenHalts(op: WriteOp) async throws {
        let harness = try await harness(op)
        await harness.transport.enterDebugLoop(text: "err lfs 6327")
        await expectRefused(op, .debugLoop, harness)
        await expectRefused(op, .halted, harness)
        await harness.client.disconnect()
    }
    
    @Test(arguments: WriteOp.allCases)
    func interruptedTransferRefuses(op: WriteOp) async throws {
        let harness = try await harness(op, interrupted: true)
        await expectRefused(op, .transferInterrupted, harness)
        await harness.client.disconnect()
    }
    
    @Test(arguments: WriteOp.allCases)
    func pendingRecoveryInTheStoreRefuses(op: WriteOp) async throws {
        let harness = try await harness(op)
        let record = PendingRecovery(checkpointID: UUID(), fid: 5, operation: .put, step: .put, reason: "timeout")
        try await harness.store.savePendingRecovery(record)
        await expectRefused(op, .pendingRecovery, harness)
        await harness.client.disconnect()
    }
    
    @Test(arguments: WriteOp.allCases)
    func unreadablePendingStateRefuses(op: WriteOp) async throws {
        let harness = try await harness(op)
        await harness.store.setPendingError(StoreFailure())
        await expectRefused(op, .checkpointFailed, harness)
        await harness.client.disconnect()
    }
    
    @Test(arguments: WriteOp.allCases, [UInt16(0), 1000])
    func fidsOutsideSampleSlotsRefuse(op: WriteOp, fid: UInt16) async throws {
        let harness = try await harness(op)
        await expectRefused(op, .notSampleSlot, harness, slot: fid)
        await harness.client.disconnect()
    }
    
    @Test func putOnAnOccupiedSlotRefuses() async throws {
        let harness = try await GuardHarness.make(nodes: [Self.sample])
        await expectRefused(.put, .slotOccupied, harness)
        await harness.client.disconnect()
    }
    
    @Test(arguments: [WriteOp.replace, .delete, .setMetadata])
    func changingAnEmptySlotRefuses(op: WriteOp) async throws {
        let harness = try await GuardHarness.make()
        await expectRefused(op, .slotEmpty, harness)
        await harness.client.disconnect()
    }
    
    @Test(
        arguments: [WriteOp.put, .replace],
        ["", "é", "abcdefghijklmnopq", "a\u{07}b", "a\u{7F}"]
    )
    func invalidNamesRefuse(op: WriteOp, name: String) async throws {
        let harness = try await harness(op)
        await expectRefused(op, .invalidName, harness, name: name)
        await harness.client.disconnect()
    }
    
    @Test func sixteenCharacterNameIsAccepted() async throws {
        let harness = try await harness(.put)
        #expect(await call(.put, harness, name: "abcdefghijklmnop") == nil)
        await harness.client.disconnect()
    }
    
    @Test func setMetadataWithAnInvalidNameRefuses() async throws {
        let harness = try await harness(.setMetadata)
        await expectRefused(.setMetadata, .invalidName, harness, json: #"{"name":"é"}"#)
        await harness.client.disconnect()
    }
    
    @Test(arguments: [WriteOp.put, .replace], [[UInt8](), [1, 2, 3]])
    func invalidDataRefuses(op: WriteOp, data: [UInt8]) async throws {
        let harness = try await harness(op)
        await expectRefused(op, .invalidData, harness, data: data)
        await harness.client.disconnect()
    }
    
    @Test(arguments: ["{}", "[]", "not json", #"{"a":{}}"#])
    func invalidMetadataRefuses(json: String) async throws {
        let harness = try await harness(.setMetadata)
        await expectRefused(.setMetadata, .invalidMetadata, harness, json: json)
        await harness.client.disconnect()
    }
    
    @Test(arguments: [#"{"crc":1}"#, #"{"channels":2}"#, #"{"samplerate":1}"#, #"{"format":"s8"}"#])
    func readOnlyKeysRefuse(json: String) async throws {
        let harness = try await harness(.setMetadata)
        await expectRefused(.setMetadata, .readOnlyKey, harness, json: json)
        await harness.client.disconnect()
    }
    
    // MARK: - #7 checkpoint before write
    
    @Test(arguments: WriteOp.allCases)
    func checkpointSaveFailureRefusesAndLeavesTheDeviceUntouched(op: WriteOp) async throws {
        let harness = try await harness(op)
        await harness.store.setSaveError(StoreFailure())
        await expectRefused(op, .checkpointFailed, harness)
        let stored = await harness.transport.device.fileSystem.node(5)
        if op == .put {
            #expect(stored == nil)
        } else {
            #expect(stored?.data == Self.sample.data)
            #expect(stored?.metadata == Self.sample.metadata)
        }
        #expect(await harness.store.pending == nil)
        await harness.client.disconnect()
    }
    
    @Test(arguments: WriteOp.allCases)
    func checkpointIsSavedBeforeAnyWriteFrame(op: WriteOp) async throws {
        let harness = try await harness(op)
        let probe = CountProbe()
        let transport = harness.transport
        await harness.store.setOnSave { _ in
            await probe.record(await writeCounts(transport))
        }
        #expect(await call(op, harness) == nil)
        #expect(await probe.counts == WriteCounts())
        #expect(await writeCounts(transport) != WriteCounts())
        await harness.client.disconnect()
    }
    
    // MARK: - #8 nothing is sent after a timeout
    
    @Test func putPageTimeoutStopsAtTheSilencedPage() async throws {
        let harness = try await harness(.put)
        let data = GuardHarness.pcm(count: 2000)
        #expect(GuardHarness.putFrameCount(dataCount: data.count) >= 4)
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 1, times: nil)
        let record = expectUnknown(await call(.put, harness, data: data), step: .put)
        #expect(await writeCounts(harness.transport) == WriteCounts(open: 1, page: 2))
        await expectBlocked(harness, try #require(record))
    }
    
    @Test func putMetadataTimeoutDoesNotRollBack() async throws {
        let harness = try await harness(.put)
        await harness.transport.inject(.silence(opcode: [0x07, 0x01]), skip: 0, times: nil)
        let record = expectUnknown(await call(.put, harness), step: .metadataSet)
        let counts = await writeCounts(harness.transport)
        #expect(counts.delete == 0)
        #expect(counts.metaSet == 1)
        await expectBlocked(harness, try #require(record))
    }
    
    @Test func putRollbackDeleteTimeoutSendsOneDelete() async throws {
        let harness = try await harness(.put)
        await harness.transport.inject(.corruptCommit, skip: 0, times: 1)
        await harness.transport.inject(.silence(opcode: [0x06]), skip: 0, times: nil)
        let record = expectUnknown(await call(.put, harness), step: .rollback)
        let counts = await writeCounts(harness.transport)
        #expect(counts.delete == 1)
        #expect(counts.open == 1)
        await expectBlocked(harness, try #require(record))
    }
    
    @Test func debugFramePutHaltsAndSendsNothingMore() async throws {
        let harness = try await harness(.put)
        await harness.transport.inject(.debugLoop(onOpcode: [0x02, 0x01], text: "err lfs 6327"))
        let record = expectUnknown(await call(.put, harness), step: .put)
        #expect(await harness.client.isHalted)
        let counts = await writeCounts(harness.transport)
        #expect(counts.delete == 0)
        #expect(counts.metaSet == 0)
        await expectBlocked(harness, try #require(record), refusal: .halted)
    }
    
    @Test func deleteTimeoutSendsOneDeleteOnly() async throws {
        let harness = try await harness(.delete)
        await harness.transport.inject(.silence(opcode: [0x06]), skip: 0, times: nil)
        let record = expectUnknown(await call(.delete, harness), step: .delete)
        #expect(await writeCounts(harness.transport) == WriteCounts(delete: 1))
        await expectBlocked(harness, try #require(record))
    }
    
    @Test func replaceDeleteTimeoutNeverPuts() async throws {
        let harness = try await harness(.replace)
        await harness.transport.inject(.silence(opcode: [0x06]), skip: 0, times: nil)
        let record = expectUnknown(await call(.replace, harness), step: .delete)
        #expect(await writeCounts(harness.transport) == WriteCounts(delete: 1))
        await expectBlocked(harness, try #require(record))
    }
    
    @Test func replacePutTimeoutNeverRestores() async throws {
        let harness = try await harness(.replace)
        let data = GuardHarness.pcm(count: 2000)
        await harness.transport.inject(.silence(opcode: [0x02, 0x01]), skip: 1, times: nil)
        let record = expectUnknown(await call(.replace, harness, data: data), step: .put)
        #expect(await writeCounts(harness.transport) == WriteCounts(open: 1, page: 2, delete: 1))
        await expectBlocked(harness, try #require(record))
    }
    
    @Test func replaceMetadataTimeoutNeverRestores() async throws {
        let harness = try await harness(.replace)
        await harness.transport.inject(.silence(opcode: [0x07, 0x01]), skip: 0, times: nil)
        let record = expectUnknown(await call(.replace, harness), step: .metadataSet)
        let counts = await writeCounts(harness.transport)
        #expect(counts.delete == 1)
        #expect(counts.open == 1)
        #expect(counts.metaSet == 1)
        await expectBlocked(harness, try #require(record))
    }
    
    @Test func metadataSetTimeoutNeverRestores() async throws {
        let harness = try await harness(.setMetadata)
        await harness.transport.inject(.silence(opcode: [0x07, 0x01]), skip: 0, times: nil)
        let record = expectUnknown(await call(.setMetadata, harness), step: .metadataSet)
        #expect(await writeCounts(harness.transport) == WriteCounts(metaSet: 1))
        await expectBlocked(harness, try #require(record))
    }
}
