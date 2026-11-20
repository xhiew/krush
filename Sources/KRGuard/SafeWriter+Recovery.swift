//
//  SafeWriter+Recovery.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
import KRCore
@_spi(UnsafeDeviceLab) import KRFile

extension SafeWriter {
    /// Re-reads the slot of the pending recovery and returns it next to the checkpoint. Sends no write frame.
    /// `nil` when nothing is pending. The slot data is read only when its size matches the checkpoint.
    public func inspectRecovery() async throws(SafeWriteError) -> RecoveryInspection? {
        try await run { await self.performInspect() }
    }
    
    /// `.keep` accepts the slot as it is; `.restore` puts it back as the original checkpoint recorded it.
    /// The record is cleared only when the resolution succeeded.
    public func resolveRecovery(_ resolution: RecoveryResolution) async throws(SafeWriteError) {
        try await run { await self.performResolve(resolution) }
    }
    
    // MARK: - Inspect
    
    private func performInspect() async -> Result<RecoveryInspection?, SafeWriteError> {
        do throws(SafeWriteError) {
            return .success(try await inspect())
        } catch {
            return .failure(error)
        }
    }
    
    private func inspect() async throws(SafeWriteError) -> RecoveryInspection? {
        guard let record = try await currentRecord() else { return nil }
        let checkpoint = try await loadCheckpoint(id: record.checkpointID)
        let current = try await readCurrent(fid: record.fid, checkpoint: checkpoint)
        return RecoveryInspection(record: record, checkpoint: checkpoint, current: current)
    }
    
    private func readCurrent(fid: UInt16, checkpoint: Checkpoint?) async throws(SafeWriteError) -> SlotState {
        do throws(KRError) {
            let nodes = try await client.list(node: FileNode.soundsID)
            guard nodes.contains(where: { $0.id == fid }) else { return .absent }
            let stat = try await client.stat(fid: fid)
            let json = try await client.metadata(fid: fid)
            var data: [UInt8]?
            let expected = checkpoint?.prior?.size ?? checkpoint?.expectedSize
            if await !client.transferInterrupted, let expected, stat.size == expected {
                data = try await client.read(fid: fid).data
            }
            return .present(size: stat.size, nodeName: stat.name, data: data, metadataJSON: json)
        } catch {
            if case .deviceDebugFrame = error {
                throw .refused(.debugLoop, underlying: error)
            }
            throw .refused(.preflightFailed, underlying: error)
        }
    }
    
    // MARK: - Resolve
    
    private func performResolve(_ resolution: RecoveryResolution) async -> Result<Void, SafeWriteError> {
        do throws(SafeWriteError) {
            guard let record = try await currentRecord() else { return .success(()) }
            if case .restore = resolution {
                try await restore(record)
            }
            do {
                try await store.clearPendingRecovery()
            } catch {
                throw .refused(.checkpointFailed, underlying: nil)
            }
            pendingInMemory = nil
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    
    private func restore(_ record: PendingRecovery) async throws(SafeWriteError) {
        let request = WriteRequest.restore(slot: record.fid)
        let snapshot = try await preflight(request)
        guard let original = try await loadCheckpoint(id: record.checkpointID) else {
            throw .refused(.checkpointFailed, underlying: nil)
        }
        _ = try await checkpoint(request, snapshot: snapshot, captureData: false)
        let outcome: RestoreOutcome
        if original.operation == .setMetadata {
            outcome = await restoreMetadata(from: original, generation: snapshot.generation)
        } else if original.slotWasEmpty {
            outcome = await restoreEmptySlot(from: original, generation: snapshot.generation)
        } else {
            outcome = await restoreSlot(from: original, generation: snapshot.generation)
        }
        switch outcome {
        case .restored, .extraKeysRemain:
            return
        case .notRestored, .unknown:
            throw restoreFailure(outcome, underlying: nil)
        }
    }
    
    /// The checkpoint recorded an empty slot: delete whatever is there.
    private func restoreEmptySlot(from checkpoint: Checkpoint, generation: UInt64) async -> RestoreOutcome {
        switch await matches(checkpoint: checkpoint) {
        case true?:
            return .restored
        case nil:
            return await recoveryUnknown(checkpoint, "slot unreadable before restore")
        case false?:
            break
        }
        let fid = checkpoint.fid
        do throws(KRError) {
            try await client.delete(fid: fid)
        } catch {
            switch await classify(error, generation: generation) {
            case .healthy:
                return await recoveryPending(checkpoint, String(describing: error))
            case .unknown:
                return await recoveryUnknown(checkpoint, String(describing: error))
            }
        }
        if await connectionChanged(since: generation) {
            return await recoveryUnknown(checkpoint, "connection re-established")
        }
        switch await verifyAbsent(fid: fid) {
        case .match:
            return .restored
        case .mismatch:
            return await recoveryPending(checkpoint, "slot still present after restore")
        case .readFailed(let error):
            return await recoveryUnknown(checkpoint, String(describing: error))
        }
    }
    
    private func recoveryPending(_ checkpoint: Checkpoint, _ reason: String) async -> RestoreOutcome {
        let (record, saved) = await recordPending(step: .rollback, checkpoint: checkpoint, reason: reason)
        guard saved else { return .unknown(.outcomeUnknown(record, recordSaved: false)) }
        return .notRestored(record)
    }
    
    private func recoveryUnknown(_ checkpoint: Checkpoint, _ reason: String) async -> RestoreOutcome {
        .unknown(await unknownOutcome(step: .rollback, checkpoint: checkpoint, reason: reason))
    }
    
    // MARK: - Shared
    
    /// The record kept in memory wins; otherwise the store is asked.
    private func currentRecord() async throws(SafeWriteError) -> PendingRecovery? {
        if let pendingInMemory { return pendingInMemory }
        let stored: PendingRecovery?
        do {
            stored = try await store.pendingRecovery()
        } catch {
            throw .refused(.checkpointFailed, underlying: nil)
        }
        pendingInMemory = stored
        return stored
    }
    
    private func loadCheckpoint(id: UUID) async throws(SafeWriteError) -> Checkpoint? {
        do {
            return try await store.load(id: id)
        } catch {
            throw .refused(.checkpointFailed, underlying: nil)
        }
    }
}
