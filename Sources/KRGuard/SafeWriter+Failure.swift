//
//  SafeWriter+Failure.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import KRCore
@_spi(UnsafeDeviceLab) import KRFile

extension SafeWriter {
    enum Health {
        case healthy
        case unknown
    }
    
    /// `healthy` only for a clean rejection from a connected, running device on the same connection:
    /// anything else may have left a write half applied, so nothing more is sent.
    func classify(_ error: KRError, generation: UInt64) async -> Health {
        guard case .statusRejected = error else { return .unknown }
        return await isHealthy(generation: generation) ? .healthy : .unknown
    }
    
    func isHealthy(generation: UInt64) async -> Bool {
        guard await client.isConnected else { return false }
        if await client.isHalted {
            return false
        }
        if await client.transferInterrupted {
            return false
        }
        return await !connectionChanged(since: generation)
    }
    
    /// Records the pending recovery and builds the error. The caller must not send another write frame afterwards.
    func unknownOutcome(step: WriteStep, checkpoint: Checkpoint, reason: String) async -> SafeWriteError {
        let (record, saved) = await recordPending(step: step, checkpoint: checkpoint, reason: reason)
        return .outcomeUnknown(record, recordSaved: saved)
    }
    
    func ensureSameConnection(
        _ generation: UInt64,
        checkpoint: Checkpoint,
        step: WriteStep
    ) async throws(SafeWriteError) {
        if await connectionChanged(since: generation) {
            throw await unknownOutcome(step: step, checkpoint: checkpoint, reason: "connection re-established")
        }
    }
    
    /// A write command of a put failed: roll back when the device is healthy, otherwise stop.
    func putStepFailed(
        _ error: KRError,
        step: WriteStep,
        checkpoint: Checkpoint,
        generation: UInt64
    ) async -> SafeWriteError {
        switch await classify(error, generation: generation) {
        case .healthy:
            return await rollbackPut(checkpoint, generation: generation, underlying: error)
        case .unknown:
            return await unknownOutcome(step: step, checkpoint: checkpoint, reason: String(describing: error))
        }
    }
    
    /// Retention failures are ignored: the write already succeeded and a store that could not prune only keeps extra checkpoints.
    func pruneCheckpoints(fid: UInt16) async {
        try? await store.prune(fid: fid, keep: configuration.checkpointsPerSlot)
    }
}
