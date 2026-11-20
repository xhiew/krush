//
//  InMemoryCheckpointStore.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
@testable import KRGuard

struct StoreFailure: Error, Equatable {}

actor InMemoryCheckpointStore: CheckpointStore {
    enum Event: Equatable {
        case save(UUID)
        case load(UUID)
        case prune(fid: UInt16, keep: Int)
        case savePending
        case loadPending
        case clearPending
    }
    
    private(set) var events: [Event] = []
    private(set) var checkpoints: [Checkpoint] = []
    private(set) var pending: PendingRecovery?
    
    var saveError: (any Error)?
    var loadError: (any Error)?
    var pruneError: (any Error)?
    var savePendingError: (any Error)?
    var pendingError: (any Error)?
    var clearPendingError: (any Error)?
    var onSave: (@Sendable (Checkpoint) async -> Void)?
    
    func setSaveError(_ error: (any Error)?) { saveError = error }
    func setLoadError(_ error: (any Error)?) { loadError = error }
    func setPruneError(_ error: (any Error)?) { pruneError = error }
    func setSavePendingError(_ error: (any Error)?) { savePendingError = error }
    func setPendingError(_ error: (any Error)?) { pendingError = error }
    func setClearPendingError(_ error: (any Error)?) { clearPendingError = error }
    func setOnSave(_ hook: (@Sendable (Checkpoint) async -> Void)?) { onSave = hook }
    
    func save(_ checkpoint: Checkpoint) async throws {
        if let saveError { throw saveError }
        if let onSave { await onSave(checkpoint) }
        checkpoints.append(checkpoint)
        events.append(.save(checkpoint.id))
    }
    
    func load(id: UUID) async throws -> Checkpoint? {
        events.append(.load(id))
        if let loadError { throw loadError }
        return checkpoints.first { $0.id == id }
    }
    
    func prune(fid: UInt16, keep: Int) async throws {
        events.append(.prune(fid: fid, keep: keep))
        if let pruneError { throw pruneError }
        let referenced = pending?.checkpointID
        let slot = checkpoints.filter { $0.fid == fid }
        let kept = Set(slot.sorted { $0.createdAt > $1.createdAt }.prefix(keep).map(\.id))
        checkpoints.removeAll { $0.fid == fid && !kept.contains($0.id) && $0.id != referenced }
    }
    
    func savePendingRecovery(_ record: PendingRecovery) async throws {
        events.append(.savePending)
        if let savePendingError { throw savePendingError }
        pending = record
    }
    
    func pendingRecovery() async throws -> PendingRecovery? {
        events.append(.loadPending)
        if let pendingError { throw pendingError }
        return pending
    }
    
    func clearPendingRecovery() async throws {
        events.append(.clearPending)
        if let clearPendingError { throw clearPendingError }
        pending = nil
    }
}
