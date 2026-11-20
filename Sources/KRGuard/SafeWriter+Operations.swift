//
//  SafeWriter+Operations.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
import KRCore
@_spi(UnsafeDeviceLab) import KRFile

extension SafeWriter {
    /// Writes a sample into an empty slot. With `verifyBytes` the data is read back byte for byte,
    /// otherwise only the size and name are checked.
    public func put(
        slot: UInt16,
        data: [UInt8],
        metadata: SampleMetadata,
        verifyBytes: Bool = true,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws(SafeWriteError) {
        try await run {
            await self.performPut(slot: slot, data: data, metadata: metadata, verifyBytes: verifyBytes, progress: progress)
        }
    }
    
    /// Replaces an occupied slot: the old sample is backed up, deleted, then the new one is put.
    public func replace(
        slot: UInt16,
        data: [UInt8],
        metadata: SampleMetadata,
        verifyBytes: Bool = true,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws(SafeWriteError) {
        try await run {
            await self.capture { () async throws(SafeWriteError) in
                try await self.replaceSample(slot: slot, data: data, metadata: metadata, verifyBytes: verifyBytes, progress: progress)
            }
        }
    }
    
    /// Merges `json` into the slot metadata. Read-only keys are refused.
    public func setMetadata(slot: UInt16, json: String) async throws(SafeWriteError) {
        try await run {
            await self.capture { () async throws(SafeWriteError) in try await self.setSlotMetadata(slot: slot, json: json) }
        }
    }
    
    /// Deletes a sample after backing up its data and metadata.
    public func delete(slot: UInt16) async throws(SafeWriteError) {
        try await run { await self.performDelete(slot: slot) }
    }
    
    private func capture(_ body: () async throws(SafeWriteError) -> Void) async -> Result<Void, SafeWriteError> {
        do throws(SafeWriteError) {
            try await body()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    
    private func performPut(
        slot: UInt16,
        data: [UInt8],
        metadata: SampleMetadata,
        verifyBytes: Bool,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async -> Result<Void, SafeWriteError> {
        do throws(SafeWriteError) {
            try await putSample(slot: slot, data: data, metadata: metadata, verifyBytes: verifyBytes, progress: progress)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    
    private func putSample(
        slot: UInt16,
        data: [UInt8],
        metadata: SampleMetadata,
        verifyBytes: Bool,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws(SafeWriteError) {
        let request = WriteRequest.put(slot: slot, data: data, metadata: metadata)
        guard let json = request.postPutMetadata else {
            throw .refused(.invalidMetadata, underlying: nil)
        }
        let snapshot = try await preflight(request)
        let checkpoint = try await checkpoint(request, snapshot: snapshot, captureData: false)
        let generation = snapshot.generation
        do throws(KRError) {
            try await client.write(
                fid: slot,
                parent: FileNode.soundsID,
                name: String(format: "%03d.pcm", Int(slot)),
                flags: .sound,
                data: data,
                progress: progress
            )
        } catch {
            throw await putStepFailed(error, step: .put, checkpoint: checkpoint, generation: generation)
        }
        try await ensureSameConnection(generation, checkpoint: checkpoint, step: .metadataSet)
        do throws(KRError) {
            try await client.setMetadata(fid: slot, json: json.serialized)
        } catch {
            throw await putStepFailed(error, step: .metadataSet, checkpoint: checkpoint, generation: generation)
        }
        try await ensureSameConnection(generation, checkpoint: checkpoint, step: .verify)
        switch await verifySample(fid: slot, data: data, name: metadata.name, verifyBytes: verifyBytes) {
        case .match:
            break
        case .mismatch:
            guard await isHealthy(generation: generation) else {
                throw await unknownOutcome(step: .verify, checkpoint: checkpoint, reason: "device unhealthy after verify mismatch")
            }
            throw await rollbackPut(checkpoint, generation: generation, underlying: nil)
        case .readFailed(let error):
            throw await unknownOutcome(step: .verify, checkpoint: checkpoint, reason: String(describing: error))
        }
        await pruneCheckpoints(fid: slot)
    }
    
    private func performDelete(slot: UInt16) async -> Result<Void, SafeWriteError> {
        do throws(SafeWriteError) {
            try await deleteSample(slot: slot)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    
    private func deleteSample(slot: UInt16) async throws(SafeWriteError) {
        let request = WriteRequest.delete(slot: slot)
        let snapshot = try await preflight(request)
        let checkpoint = try await checkpoint(request, snapshot: snapshot, captureData: true)
        let generation = snapshot.generation
        do throws(KRError) {
            try await client.delete(fid: slot)
        } catch {
            switch await classify(error, generation: generation) {
            case .healthy:
                throw await deleteNotApplied(checkpoint, step: .delete, underlying: error)
            case .unknown:
                throw await unknownOutcome(step: .delete, checkpoint: checkpoint, reason: String(describing: error))
            }
        }
        try await ensureSameConnection(generation, checkpoint: checkpoint, step: .verify)
        switch await verifyAbsent(fid: slot) {
        case .match:
            break
        case .mismatch:
            guard await isHealthy(generation: generation) else {
                throw await unknownOutcome(step: .verify, checkpoint: checkpoint, reason: "device unhealthy after verify mismatch")
            }
            throw await deleteNotApplied(checkpoint, step: .verify, underlying: nil)
        case .readFailed(let error):
            throw await unknownOutcome(step: .verify, checkpoint: checkpoint, reason: String(describing: error))
        }
        await pruneCheckpoints(fid: slot)
    }
    
    /// The delete did not take effect. Nothing is left to recover only when the slot provably equals the checkpoint.
    private func deleteNotApplied(_ checkpoint: Checkpoint, step: WriteStep, underlying: KRError?) async -> SafeWriteError {
        switch await matches(checkpoint: checkpoint) {
        case true?:
            return .verifyFailed(rolledBack: false, underlying: underlying, pending: nil)
        case false?:
            let (record, saved) = await recordPending(step: step, checkpoint: checkpoint, reason: "slot differs from checkpoint after delete")
            guard saved else { return .outcomeUnknown(record, recordSaved: false) }
            return .verifyFailed(rolledBack: false, underlying: underlying, pending: record)
        case nil:
            return await unknownOutcome(step: step, checkpoint: checkpoint, reason: "slot unreadable after delete")
        }
    }
    
    private func replaceSample(
        slot: UInt16,
        data: [UInt8],
        metadata: SampleMetadata,
        verifyBytes: Bool,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws(SafeWriteError) {
        let request = WriteRequest.replace(slot: slot, data: data, metadata: metadata)
        guard let json = request.postPutMetadata else {
            throw .refused(.invalidMetadata, underlying: nil)
        }
        let snapshot = try await preflight(request)
        let checkpoint = try await checkpoint(request, snapshot: snapshot, captureData: true)
        let generation = snapshot.generation
        do throws(KRError) {
            try await client.delete(fid: slot)
        } catch {
            throw await replaceStepFailed(error, step: .delete, checkpoint: checkpoint, generation: generation)
        }
        try await ensureSameConnection(generation, checkpoint: checkpoint, step: .put)
        switch await verifyAbsent(fid: slot) {
        case .match:
            break
        case .mismatch:
            throw await replaceMismatch(checkpoint, generation: generation, step: .delete)
        case .readFailed(let error):
            throw await unknownOutcome(step: .delete, checkpoint: checkpoint, reason: String(describing: error))
        }
        do throws(KRError) {
            try await client.write(
                fid: slot,
                parent: FileNode.soundsID,
                name: String(format: "%03d.pcm", Int(slot)),
                flags: .sound,
                data: data,
                progress: progress
            )
        } catch {
            throw await replaceStepFailed(error, step: .put, checkpoint: checkpoint, generation: generation)
        }
        try await ensureSameConnection(generation, checkpoint: checkpoint, step: .metadataSet)
        do throws(KRError) {
            try await client.setMetadata(fid: slot, json: json.serialized)
        } catch {
            throw await replaceStepFailed(error, step: .metadataSet, checkpoint: checkpoint, generation: generation)
        }
        try await ensureSameConnection(generation, checkpoint: checkpoint, step: .verify)
        switch await verifySample(fid: slot, data: data, name: metadata.name, verifyBytes: verifyBytes) {
        case .match:
            break
        case .mismatch:
            throw await replaceMismatch(checkpoint, generation: generation, step: .verify)
        case .readFailed(let error):
            throw await unknownOutcome(step: .verify, checkpoint: checkpoint, reason: String(describing: error))
        }
        await pruneCheckpoints(fid: slot)
    }
    
    /// A command of a replace failed: restore from the checkpoint when the device is healthy, otherwise stop.
    private func replaceStepFailed(
        _ error: KRError,
        step: WriteStep,
        checkpoint: Checkpoint,
        generation: UInt64
    ) async -> SafeWriteError {
        switch await classify(error, generation: generation) {
        case .healthy:
            return restoreFailure(await restoreSlot(from: checkpoint, generation: generation), underlying: error)
        case .unknown:
            return await unknownOutcome(step: step, checkpoint: checkpoint, reason: String(describing: error))
        }
    }
    
    private func replaceMismatch(_ checkpoint: Checkpoint, generation: UInt64, step: WriteStep) async -> SafeWriteError {
        guard await isHealthy(generation: generation) else {
            return await unknownOutcome(step: step, checkpoint: checkpoint, reason: "device unhealthy after verify mismatch")
        }
        return restoreFailure(await restoreSlot(from: checkpoint, generation: generation), underlying: nil)
    }
    
    private func setSlotMetadata(slot: UInt16, json: String) async throws(SafeWriteError) {
        let request = WriteRequest.setMetadata(slot: slot, json: json)
        let snapshot = try await preflight(request)
        let checkpoint = try await checkpoint(request, snapshot: snapshot, captureData: false)
        let generation = snapshot.generation
        guard let expected = MetadataJSON(parsing: json) else {
            throw .refused(.invalidMetadata, underlying: nil)
        }
        do throws(KRError) {
            try await client.setMetadata(fid: slot, json: json)
        } catch {
            switch await classify(error, generation: generation) {
            case .healthy:
                throw restoreFailure(await restoreMetadata(from: checkpoint, generation: generation), underlying: error)
            case .unknown:
                throw await unknownOutcome(step: .metadataSet, checkpoint: checkpoint, reason: String(describing: error))
            }
        }
        try await ensureSameConnection(generation, checkpoint: checkpoint, step: .verify)
        switch await verifyKeys(fid: slot, expected: expected) {
        case .match:
            break
        case .mismatch:
            guard await isHealthy(generation: generation) else {
                throw await unknownOutcome(step: .verify, checkpoint: checkpoint, reason: "device unhealthy after verify mismatch")
            }
            throw restoreFailure(await restoreMetadata(from: checkpoint, generation: generation), underlying: nil)
        case .readFailed(let error):
            throw await unknownOutcome(step: .verify, checkpoint: checkpoint, reason: String(describing: error))
        }
        await pruneCheckpoints(fid: slot)
    }
}
