//
//  CheckpointStore.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation

/// Persistence supplied by the app.
///
/// - `save` returns only once the checkpoint is durably stored; the first write frame is sent after it returns.
/// - `prune` never deletes a checkpoint referenced by the stored pending recovery.
public protocol CheckpointStore: Sendable {
    func save(_ checkpoint: Checkpoint) async throws
    
    func load(id: UUID) async throws -> Checkpoint?
    
    /// Keeps the newest `keep` checkpoints of `fid`.
    func prune(fid: UInt16, keep: Int) async throws
    
    func savePendingRecovery(_ record: PendingRecovery) async throws
    
    func pendingRecovery() async throws -> PendingRecovery?
    
    func clearPendingRecovery() async throws
}
