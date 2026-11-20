//
//  SafeWriterPreflightTests.swift
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
struct SafeWriterPreflightTests {
    private static let metadata = SampleMetadata(name: "kick", channels: 1)
    
    private static func put(_ slot: UInt16 = 5, count: Int = 64, name: String = "kick", channels: UInt8 = 1) -> WriteRequest {
        .put(slot: slot, data: GuardHarness.pcm(count: count), metadata: SampleMetadata(name: name, channels: channels))
    }
    
    private func refusal(_ request: WriteRequest, _ harness: GuardHarness) async -> SafeWriteError? {
        do throws(SafeWriteError) {
            _ = try await harness.writer.preflight(request)
            return nil
        } catch {
            return error
        }
    }
    
    private func expectRefused(
        _ request: WriteRequest,
        _ reason: SafeWriteRefusal,
        _ harness: GuardHarness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let error = await refusal(request, harness)
        guard case .refused(let actual, _)? = error else {
            Issue.record("expected refused(\(reason)), got \(String(describing: error))", sourceLocation: sourceLocation)
            return
        }
        #expect(actual == reason, sourceLocation: sourceLocation)
        #expect(await harness.writeFrames().isEmpty, sourceLocation: sourceLocation)
    }
    
    // MARK: - Client and store state
    
    @Test func refusesWhenNotConnected() async throws {
        let harness = try await GuardHarness.make(connected: false)
        await expectRefused(Self.put(), .notConnected, harness)
    }
    
    @Test func refusesWhenDeviceIsDebugging() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.enterDebugLoop(text: "err lfs 6327")
        await expectRefused(Self.put(), .debugLoop, harness)
        await harness.client.disconnect()
    }
    
    @Test func refusesWhenHalted() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.enterDebugLoop(text: "err lfs 6327")
        await expectRefused(Self.put(), .debugLoop, harness)
        #expect(await harness.client.isHalted)
        await expectRefused(Self.put(), .halted, harness)
        await harness.client.disconnect()
    }
    
    @Test func refusesWhenTransferWasInterrupted() async throws {
        let harness = try await GuardHarness.make(interruptedTransfer: true)
        await expectRefused(Self.put(), .transferInterrupted, harness)
        await harness.client.disconnect()
    }
    
    @Test func refusesWhenRecoveryIsPendingInStore() async throws {
        let harness = try await GuardHarness.make()
        let record = PendingRecovery(checkpointID: UUID(), fid: 5, operation: .put, step: .put, reason: "timeout")
        try await harness.store.savePendingRecovery(record)
        await expectRefused(Self.put(), .pendingRecovery, harness)
        #expect(await harness.writer.pendingInMemory == record)
        await harness.client.disconnect()
    }
    
    @Test func refusesWhenRecoveryIsPendingInMemory() async throws {
        let harness = try await GuardHarness.make()
        let checkpoint = Checkpoint(fid: 5, operation: .put, prior: nil)
        _ = await harness.writer.recordPending(step: .put, checkpoint: checkpoint, reason: "timeout")
        await harness.store.setSavePendingError(StoreFailure())
        await expectRefused(Self.put(), .pendingRecovery, harness)
        await harness.client.disconnect()
    }
    
    @Test func restoreIgnoresPendingRecovery() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let checkpoint = Checkpoint(fid: 5, operation: .put, prior: nil)
        _ = await harness.writer.recordPending(step: .put, checkpoint: checkpoint, reason: "timeout")
        let snapshot = try await harness.writer.preflight(.restore(slot: 5))
        #expect(snapshot.present)
        await harness.client.disconnect()
    }
    
    @Test func refusesWhenStoreCannotReportPendingRecovery() async throws {
        let harness = try await GuardHarness.make()
        await harness.store.setPendingError(StoreFailure())
        await expectRefused(Self.put(), .checkpointFailed, harness)
        await harness.client.disconnect()
    }
    
    // MARK: - Slot rules
    
    @Test(arguments: [UInt16(0), 1000, 3000])
    func refusesFidsOutsideSampleSlots(fid: UInt16) async throws {
        let harness = try await GuardHarness.make()
        await expectRefused(Self.put(fid), .notSampleSlot, harness)
        await expectRefused(.delete(slot: fid), .notSampleSlot, harness)
        await harness.client.disconnect()
    }
    
    @Test func refusesPutOnOccupiedSlot() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await expectRefused(Self.put(5), .slotOccupied, harness)
        await harness.client.disconnect()
    }
    
    @Test func refusesReplaceDeleteAndMetadataOnEmptySlot() async throws {
        let harness = try await GuardHarness.make()
        await expectRefused(.replace(slot: 5, data: GuardHarness.pcm(count: 8), metadata: Self.metadata), .slotEmpty, harness)
        await expectRefused(.delete(slot: 5), .slotEmpty, harness)
        await expectRefused(.setMetadata(slot: 5, json: #"{"name":"a"}"#), .slotEmpty, harness)
        await harness.client.disconnect()
    }
    
    @Test func snapshotReflectsTheSlot() async throws {
        let node = GuardHarness.sample(5, count: 700)
        let harness = try await GuardHarness.make(nodes: [node])
        let occupied = try await harness.writer.preflight(.delete(slot: 5))
        #expect(occupied.present)
        #expect(occupied.stat?.size == 700)
        #expect(occupied.stat?.name == node.name)
        #expect(MetadataJSON(parsing: occupied.metadataJSON ?? "")?.entries["name"] == .string("old5"))
        let empty = try await harness.writer.preflight(Self.put(6))
        #expect(!empty.present)
        #expect(empty.stat == nil)
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    // MARK: - Input validation
    
    @Test(arguments: ["", "é", "this name is far too long"])
    func refusesInvalidNames(name: String) async throws {
        let harness = try await GuardHarness.make()
        await expectRefused(Self.put(name: name), .invalidName, harness)
        await harness.client.disconnect()
    }
    
    @Test func acceptsNameAtTheLimit() async throws {
        let harness = try await GuardHarness.make()
        _ = try await harness.writer.preflight(Self.put(name: String(repeating: "a", count: 16)))
        await harness.client.disconnect()
    }
    
    @Test func refusesInvalidData() async throws {
        let harness = try await GuardHarness.make()
        let limit = await harness.client.maxWriteDataBytes
        await expectRefused(Self.put(count: 0), .invalidData, harness)
        await expectRefused(Self.put(count: 3), .invalidData, harness)
        await expectRefused(Self.put(channels: 3), .invalidData, harness)
        await expectRefused(Self.put(count: limit + 2), .invalidData, harness)
        await expectRefused(Self.put(count: 6, channels: 2), .invalidData, harness)
        _ = try await harness.writer.preflight(Self.put(count: 8, channels: 2))
        await harness.client.disconnect()
    }
    
    @Test(arguments: ["{}", "[]", #"{"a":{}}"#, "not json"])
    func refusesInvalidMetadata(json: String) async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await expectRefused(.setMetadata(slot: 5, json: json), .invalidMetadata, harness)
        await harness.client.disconnect()
    }
    
    @Test func enforcesTheMetadataSizeLimit() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        let limit = await harness.client.maxMetadataJSONBytes
        #expect(limit == 428)
        let wrapper = #"{"a":""}"#.utf8.count
        let fits = #"{"a":""# + String(repeating: "x", count: limit - wrapper) + #""}"#
        let tooLong = #"{"a":""# + String(repeating: "x", count: limit - wrapper + 1) + #""}"#
        #expect(fits.utf8.count == 428)
        #expect(tooLong.utf8.count == 429)
        await expectRefused(.setMetadata(slot: 5, json: tooLong), .invalidMetadata, harness)
        _ = try await harness.writer.preflight(.setMetadata(slot: 5, json: fits))
        await harness.client.disconnect()
    }
    
    @Test(arguments: [#"{"crc":1}"#, #"{"channels":2}"#, #"{"samplerate":1}"#, #"{"format":"s8"}"#])
    func refusesReadOnlyKeys(json: String) async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await expectRefused(.setMetadata(slot: 5, json: json), .readOnlyKey, harness)
        await harness.client.disconnect()
    }
    
    @Test func refusesInvalidNameInMetadata() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(5)])
        await expectRefused(.setMetadata(slot: 5, json: #"{"name":"é"}"#), .invalidName, harness)
        await expectRefused(.setMetadata(slot: 5, json: #"{"name":5}"#), .invalidName, harness)
        _ = try await harness.writer.preflight(.setMetadata(slot: 5, json: #"{"name":"snare"}"#))
        await harness.client.disconnect()
    }
    
    // MARK: - Device reads
    
    @Test func refusesWhenTheDeviceCannotBeRead() async throws {
        let harness = try await GuardHarness.make()
        await harness.transport.inject(.silence(opcode: [0x04]))
        let error = await refusal(Self.put(), harness)
        guard case .refused(let reason, let underlying)? = error else {
            Issue.record("expected refused, got \(String(describing: error))")
            return
        }
        #expect(reason == .preflightFailed)
        guard case .timeout? = underlying else {
            Issue.record("expected timeout, got \(String(describing: underlying))")
            return
        }
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    // MARK: - Checkpoint
    
    @Test func checkpointOfPutHasNoPriorSlot() async throws {
        let harness = try await GuardHarness.make()
        let request = Self.put(count: 64)
        let snapshot = try await harness.writer.preflight(request)
        let checkpoint = try await harness.writer.checkpoint(request, snapshot: snapshot, captureData: true)
        #expect(checkpoint.prior == nil)
        #expect(checkpoint.slotWasEmpty)
        #expect(checkpoint.operation == .put)
        #expect(checkpoint.expectedSize == 64)
        #expect(await harness.store.checkpoints == [checkpoint])
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    @Test func checkpointOfDeleteKeepsDataAndStatFields() async throws {
        let node = GuardHarness.sample(7, count: 700)
        let harness = try await GuardHarness.make(nodes: [node])
        let snapshot = try await harness.writer.preflight(.delete(slot: 7))
        let checkpoint = try await harness.writer.checkpoint(.delete(slot: 7), snapshot: snapshot, captureData: true)
        let prior = try #require(checkpoint.prior)
        #expect(prior.data == Data(node.data))
        #expect(prior.size == 700)
        #expect(prior.flags == node.flags)
        #expect(prior.nodeName == node.name)
        let parts = try #require(checkpoint.restoreMetadataParts)
        let merged = parts.compactMap { MetadataJSON(parsing: $0) }.flatMap(\.keys)
        #expect(!merged.contains("crc"))
        #expect(Set(merged) == ["name", "samplerate", "channels", "format"])
        #expect(await harness.store.checkpoints == [checkpoint])
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    @Test func checkpointSplitsLargeMetadataIntoParts() async throws {
        var metadata = ["name": "\"big\""]
        for index in 0..<8 {
            metadata["sound.key\(index)"] = "\"" + String(repeating: "v", count: 110) + "\""
        }
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(7, metadata: metadata)])
        let limit = await harness.client.maxMetadataJSONBytes
        let snapshot = try await harness.writer.preflight(.delete(slot: 7))
        let checkpoint = try await harness.writer.checkpoint(.delete(slot: 7), snapshot: snapshot, captureData: true)
        let parts = try #require(checkpoint.restoreMetadataParts)
        #expect(parts.count >= 3)
        #expect(parts.allSatisfy { $0.utf8.count <= limit })
        let merged = parts.compactMap { MetadataJSON(parsing: $0) }.flatMap(\.keys)
        #expect(Set(merged) == Set(metadata.keys))
        await harness.client.disconnect()
    }
    
    @Test func checkpointOfMetadataKeepsOnlyWrittenKeys() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(7)])
        let request = WriteRequest.setMetadata(slot: 7, json: #"{"name":"snare","sound.pan":2}"#)
        let snapshot = try await harness.writer.preflight(request)
        let checkpoint = try await harness.writer.checkpoint(request, snapshot: snapshot, captureData: true)
        #expect(checkpoint.writtenKeys == ["name", "sound.pan"])
        #expect(checkpoint.prior?.data == nil)
        #expect(checkpoint.restoreMetadataParts == nil)
        await harness.client.disconnect()
    }
    
    @Test func checkpointFailsWhenTheStoreCannotSave() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(7)])
        let snapshot = try await harness.writer.preflight(.delete(slot: 7))
        await harness.store.setSaveError(StoreFailure())
        await expectCheckpointFailure(.delete(slot: 7), snapshot, harness)
        await harness.client.disconnect()
    }
    
    @Test func checkpointFailsWhenTheBackupCannotBeRead() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(7)])
        let snapshot = try await harness.writer.preflight(.delete(slot: 7))
        await harness.transport.inject(.silence(opcode: [0x03, 0x00]))
        await expectCheckpointFailure(.delete(slot: 7), snapshot, harness)
        #expect(await harness.store.checkpoints.isEmpty)
        #expect(await harness.client.transferInterrupted)
        await expectRefused(.delete(slot: 7), .transferInterrupted, harness)
        await harness.client.disconnect()
    }
    
    @Test func checkpointFailsWhenTheOldValueExceedsTheLimit() async throws {
        let metadata = ["name": "\"" + String(repeating: "o", count: 450) + "\""]
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(7, metadata: metadata)])
        let request = WriteRequest.setMetadata(slot: 7, json: #"{"name":"a"}"#)
        let snapshot = try await harness.writer.preflight(request)
        await expectCheckpointFailure(request, snapshot, harness)
        #expect(await harness.store.checkpoints.isEmpty)
        await harness.client.disconnect()
    }
    
    @Test func checkpointFailsWhenOldMetadataCannotBeSplit() async throws {
        let metadata = ["name": "\"x\"", "sound.long": "\"" + String(repeating: "v", count: 500) + "\""]
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(7, metadata: metadata)])
        let snapshot = try await harness.writer.preflight(.delete(slot: 7))
        await expectCheckpointFailure(.delete(slot: 7), snapshot, harness)
        #expect(await harness.store.checkpoints.isEmpty)
        await harness.client.disconnect()
    }
    
    @Test func checkpointRefusesWhenTheConnectionChangedAfterPreflight() async throws {
        let harness = try await GuardHarness.make(nodes: [GuardHarness.sample(7)])
        let snapshot = try await harness.writer.preflight(.delete(slot: 7))
        await harness.client.disconnect()
        try await harness.client.connect()
        do throws(SafeWriteError) {
            _ = try await harness.writer.checkpoint(.delete(slot: 7), snapshot: snapshot, captureData: true)
            Issue.record("expected refusal")
        } catch {
            guard case .refused(.notConnected, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        #expect(await harness.writeFrames().isEmpty)
        await harness.client.disconnect()
    }
    
    private func expectCheckpointFailure(
        _ request: WriteRequest,
        _ snapshot: SlotSnapshot,
        _ harness: GuardHarness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do throws(SafeWriteError) {
            _ = try await harness.writer.checkpoint(request, snapshot: snapshot, captureData: true)
            Issue.record("expected checkpointFailed", sourceLocation: sourceLocation)
        } catch {
            guard case .refused(.checkpointFailed, _) = error else {
                Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
                return
            }
        }
        #expect(await harness.writeFrames().isEmpty, sourceLocation: sourceLocation)
    }
}
