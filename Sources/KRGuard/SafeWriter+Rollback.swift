//
//  SafeWriter+Rollback.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import KRCore
@_spi(UnsafeDeviceLab) import KRFile

enum RestoreOutcome {
    case restored
    /// Prior values are back, but keys the write added cannot be removed (BR-GUARD-019).
    case extraKeysRemain
    case notRestored(PendingRecovery)
    case unknown(SafeWriteError)
}

extension SafeWriter {
    func restoreFailure(_ outcome: RestoreOutcome, underlying: KRError?) -> SafeWriteError {
        switch outcome {
        case .restored:
            return .verifyFailed(rolledBack: true, underlying: underlying, pending: nil)
        case .extraKeysRemain:
            return .verifyFailed(rolledBack: false, underlying: underlying, pending: nil)
        case .notRestored(let record):
            return .verifyFailed(rolledBack: false, underlying: underlying, pending: record)
        case .unknown(let error):
            return error
        }
    }
    
    /// Puts the slot back as the checkpoint recorded it. Writes nothing when the slot already matches; runs once.
    func restoreSlot(from checkpoint: Checkpoint, generation: UInt64) async -> RestoreOutcome {
        let fid = checkpoint.fid
        guard let prior = checkpoint.prior,
              let old = MetadataJSON(parsing: prior.metadataJSON),
              let parts = checkpoint.restoreMetadataParts else {
            return await restorePending(checkpoint, "checkpoint holds no data to restore")
        }
        switch await matches(checkpoint: checkpoint) {
        case true?:
            return await restoreMetadataOnly(checkpoint, old: old, parts: parts, generation: generation)
        case nil:
            return await restoreUnknown(checkpoint, "slot unreadable before restore")
        case false?:
            break
        }
        guard let data = prior.data else {
            return await restorePending(checkpoint, "checkpoint holds no data to restore")
        }
        switch await verifyAbsent(fid: fid) {
        case .readFailed(let error):
            return await restoreUnknown(checkpoint, String(describing: error))
        case .mismatch:
            do throws(KRError) {
                try await client.delete(fid: fid)
            } catch {
                return await restoreStepFailed(error, checkpoint: checkpoint, generation: generation)
            }
            if await connectionChanged(since: generation) {
                return await restoreUnknown(checkpoint, "connection re-established")
            }
            switch await verifyAbsent(fid: fid) {
            case .match:
                break
            case .mismatch:
                return await restorePending(checkpoint, "slot still present after restore delete")
            case .readFailed(let error):
                return await restoreUnknown(checkpoint, String(describing: error))
            }
        case .match:
            break
        }
        if await connectionChanged(since: generation) {
            return await restoreUnknown(checkpoint, "connection re-established")
        }
        do throws(KRError) {
            try await client.write(
                fid: fid,
                parent: FileNode.soundsID,
                name: prior.nodeName,
                flags: FileCreateFlags(rawValue: prior.flags),
                data: [UInt8](data)
            )
            for part in parts {
                if await connectionChanged(since: generation) {
                    return await restoreUnknown(checkpoint, "connection re-established")
                }
                try await client.setMetadata(fid: fid, json: part)
            }
        } catch {
            return await restoreStepFailed(error, checkpoint: checkpoint, generation: generation)
        }
        if await connectionChanged(since: generation) {
            return await restoreUnknown(checkpoint, "connection re-established")
        }
        switch await matches(checkpoint: checkpoint) {
        case true?:
            break
        case false?:
            return await restorePending(checkpoint, "slot differs from checkpoint after restore")
        case nil:
            return await restoreUnknown(checkpoint, "slot unreadable after restore")
        }
        switch await verifyKeys(fid: fid, expected: old.removing(keys: ["crc"])) {
        case .match:
            return .restored
        case .mismatch:
            return await restorePending(checkpoint, "metadata differs from checkpoint after restore")
        case .readFailed(let error):
            return await restoreUnknown(checkpoint, String(describing: error))
        }
    }
    
    /// The data already matches: only the metadata keys may still differ.
    private func restoreMetadataOnly(
        _ checkpoint: Checkpoint,
        old: MetadataJSON,
        parts: [String],
        generation: UInt64
    ) async -> RestoreOutcome {
        let fid = checkpoint.fid
        let expected = old.removing(keys: ["crc"])
        switch await verifyKeys(fid: fid, expected: expected) {
        case .match:
            return .restored
        case .readFailed(let error):
            return await restoreUnknown(checkpoint, String(describing: error))
        case .mismatch:
            break
        }
        do throws(KRError) {
            for part in parts {
                if await connectionChanged(since: generation) {
                    return await restoreUnknown(checkpoint, "connection re-established")
                }
                try await client.setMetadata(fid: fid, json: part)
            }
        } catch {
            return await restoreStepFailed(error, checkpoint: checkpoint, generation: generation)
        }
        if await connectionChanged(since: generation) {
            return await restoreUnknown(checkpoint, "connection re-established")
        }
        switch await verifyKeys(fid: fid, expected: expected) {
        case .match:
            return .restored
        case .mismatch:
            return await restorePending(checkpoint, "metadata differs from checkpoint after restore")
        case .readFailed(let error):
            return await restoreUnknown(checkpoint, String(describing: error))
        }
    }
    
    /// Writes back the prior values of the keys a metadata set touched.
    func restoreMetadata(from checkpoint: Checkpoint, generation: UInt64) async -> RestoreOutcome {
        let fid = checkpoint.fid
        guard let prior = checkpoint.prior, let keys = checkpoint.writtenKeys,
              let old = MetadataJSON(parsing: prior.metadataJSON) else {
            return await restorePending(checkpoint, "checkpoint holds no prior metadata")
        }
        let oldKeys = keys.filter { old.entries[$0] != nil }
        let newKeys = keys.filter { old.entries[$0] == nil }
        guard var current = await readMetadataEntries(fid: fid) else {
            return await restoreUnknown(checkpoint, "metadata unreadable before restore")
        }
        let differing = oldKeys.filter { current.entries[$0] != old.entries[$0] }
        if !differing.isEmpty {
            do throws(KRError) {
                try await client.setMetadata(fid: fid, json: old.restricting(to: differing).serialized)
            } catch {
                return await restoreStepFailed(error, checkpoint: checkpoint, generation: generation)
            }
            if await connectionChanged(since: generation) {
                return await restoreUnknown(checkpoint, "connection re-established")
            }
            guard let reread = await readMetadataEntries(fid: fid) else {
                return await restoreUnknown(checkpoint, "metadata unreadable after restore")
            }
            current = reread
        }
        guard oldKeys.allSatisfy({ current.entries[$0] == old.entries[$0] }) else {
            return await restorePending(checkpoint, "prior metadata values not restored")
        }
        return newKeys.contains(where: { current.entries[$0] != nil }) ? .extraKeysRemain : .restored
    }
    
    private func restoreStepFailed(_ error: KRError, checkpoint: Checkpoint, generation: UInt64) async -> RestoreOutcome {
        switch await classify(error, generation: generation) {
        case .healthy:
            return await restorePending(checkpoint, String(describing: error))
        case .unknown:
            return await restoreUnknown(checkpoint, String(describing: error))
        }
    }
    
    private func restorePending(_ checkpoint: Checkpoint, _ reason: String) async -> RestoreOutcome {
        let (record, saved) = await recordPending(step: .rollback, checkpoint: checkpoint, reason: reason)
        guard saved else { return .unknown(.outcomeUnknown(record, recordSaved: false)) }
        return .notRestored(record)
    }
    
    private func restoreUnknown(_ checkpoint: Checkpoint, _ reason: String) async -> RestoreOutcome {
        .unknown(await unknownOutcome(step: .rollback, checkpoint: checkpoint, reason: reason))
    }
    
    /// Removes what a failed put left in the slot. Runs once and never repeats the original write.
    func rollbackPut(_ checkpoint: Checkpoint, generation: UInt64, underlying: KRError?) async -> SafeWriteError {
        let fid = checkpoint.fid
        switch await verifyAbsent(fid: fid) {
        case .match:
            return .verifyFailed(rolledBack: true, underlying: underlying, pending: nil)
        case .readFailed(let error):
            return await unknownOutcome(step: .rollback, checkpoint: checkpoint, reason: String(describing: error))
        case .mismatch:
            break
        }
        do throws(KRError) {
            try await client.delete(fid: fid)
        } catch {
            switch await classify(error, generation: generation) {
            case .healthy:
                return await rollbackIncomplete(checkpoint, underlying: underlying, reason: String(describing: error))
            case .unknown:
                return await unknownOutcome(step: .rollback, checkpoint: checkpoint, reason: String(describing: error))
            }
        }
        if await connectionChanged(since: generation) {
            return await unknownOutcome(step: .rollback, checkpoint: checkpoint, reason: "connection re-established")
        }
        switch await verifyAbsent(fid: fid) {
        case .match:
            return .verifyFailed(rolledBack: true, underlying: underlying, pending: nil)
        case .mismatch:
            return await rollbackIncomplete(checkpoint, underlying: underlying, reason: "slot still present after rollback")
        case .readFailed(let error):
            return await unknownOutcome(step: .rollback, checkpoint: checkpoint, reason: String(describing: error))
        }
    }
    
    private func rollbackIncomplete(_ checkpoint: Checkpoint, underlying: KRError?, reason: String) async -> SafeWriteError {
        let (record, saved) = await recordPending(step: .rollback, checkpoint: checkpoint, reason: reason)
        guard saved else { return .outcomeUnknown(record, recordSaved: false) }
        return .verifyFailed(rolledBack: false, underlying: underlying, pending: record)
    }
}
