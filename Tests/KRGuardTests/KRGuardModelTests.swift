//
//  KRGuardModelTests.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
import Testing
import KRCore
@testable import KRGuard

struct KRGuardModelTests {
    private func makeCheckpoint(
        fid: UInt16 = 1,
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        prior: Checkpoint.PriorSlot? = nil
    ) -> Checkpoint {
        Checkpoint(fid: fid, operation: .replace, createdAt: createdAt, prior: prior, writtenKeys: ["name"], expectedSize: 8, restoreMetadataParts: ["{\"name\":\"a\"}"])
    }
    
    private func makePrior() -> Checkpoint.PriorSlot {
        Checkpoint.PriorSlot(nodeName: "001.pcm", flags: 5, size: 4, data: Data([1, 2, 3, 4]), metadataJSON: "{\"name\":\"a\"}")
    }
    
    private func makeRecord(_ checkpoint: Checkpoint) -> PendingRecovery {
        PendingRecovery(checkpointID: checkpoint.id, fid: checkpoint.fid, operation: .replace, step: .put, reason: "timeout", createdAt: Date(timeIntervalSince1970: 2_000))
    }
    
    @Test func checkpointRoundTripsThroughJSON() throws {
        let checkpoint = makeCheckpoint(prior: makePrior())
        let decoded = try JSONDecoder().decode(Checkpoint.self, from: JSONEncoder().encode(checkpoint))
        #expect(decoded == checkpoint)
    }
    
    @Test func checkpointEncodesDataAsBase64AndCarriesVersion() throws {
        let checkpoint = makeCheckpoint(prior: makePrior())
        #expect(checkpoint.version == 1)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let prior = try #require(object["prior"] as? [String: Any])
        #expect(prior["data"] as? String == Data([1, 2, 3, 4]).base64EncodedString())
    }
    
    @Test func pendingRecoveryRoundTripsThroughJSON() throws {
        let record = makeRecord(makeCheckpoint())
        let decoded = try JSONDecoder().decode(PendingRecovery.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }
    
    @Test func slotWasEmptyFollowsPrior() {
        #expect(makeCheckpoint(prior: nil).slotWasEmpty)
        #expect(!makeCheckpoint(prior: makePrior()).slotWasEmpty)
    }
    
    @Test func errorEqualityDistinguishesCasesAndPending() {
        let record = makeRecord(makeCheckpoint())
        let other = makeRecord(makeCheckpoint())
        #expect(SafeWriteError.refused(.halted, underlying: nil) != .refused(.debugLoop, underlying: nil))
        #expect(SafeWriteError.refused(.halted, underlying: nil) != .refused(.halted, underlying: .disconnected))
        #expect(SafeWriteError.verifyFailed(rolledBack: true, underlying: nil, pending: nil)
            != .verifyFailed(rolledBack: false, underlying: nil, pending: nil))
        #expect(SafeWriteError.verifyFailed(rolledBack: false, underlying: nil, pending: record)
            != .verifyFailed(rolledBack: false, underlying: nil, pending: other))
        #expect(SafeWriteError.verifyFailed(rolledBack: false, underlying: nil, pending: record)
            == .verifyFailed(rolledBack: false, underlying: nil, pending: record))
        #expect(SafeWriteError.outcomeUnknown(record, recordSaved: true) != .outcomeUnknown(record, recordSaved: false))
        #expect(SafeWriteError.outcomeUnknown(record, recordSaved: true) != .refused(.halted, underlying: nil))
    }
    
    @Test func errorDescriptionIsNotEmpty() {
        let record = makeRecord(makeCheckpoint())
        let errors: [SafeWriteError] = [
            .refused(.notSampleSlot, underlying: .timeout(requestID: 1)),
            .verifyFailed(rolledBack: false, underlying: nil, pending: record),
            .outcomeUnknown(record, recordSaved: false)
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }
    
    @Test func pruneKeepsNewestAndSparesReferencedAndOtherSlots() async throws {
        let store = InMemoryCheckpointStore()
        let oldest = makeCheckpoint(createdAt: Date(timeIntervalSince1970: 1))
        let middle = makeCheckpoint(createdAt: Date(timeIntervalSince1970: 2))
        let newer = makeCheckpoint(createdAt: Date(timeIntervalSince1970: 3))
        let newest = makeCheckpoint(createdAt: Date(timeIntervalSince1970: 4))
        let otherSlot = makeCheckpoint(fid: 2, createdAt: Date(timeIntervalSince1970: 0))
        for checkpoint in [oldest, middle, newer, newest, otherSlot] {
            try await store.save(checkpoint)
        }
        try await store.savePendingRecovery(makeRecord(oldest))
        
        try await store.prune(fid: 1, keep: 2)
        
        let kept = await store.checkpoints.map(\.id)
        #expect(Set(kept) == [oldest.id, newer.id, newest.id, otherSlot.id])
        #expect(try await store.load(id: middle.id) == nil)
    }
}
