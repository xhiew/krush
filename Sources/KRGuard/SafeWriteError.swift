//
//  SafeWriteError.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import KRCore

public enum SafeWriteError: Error, Equatable, Sendable {
    case refused(SafeWriteRefusal, underlying: KRError?)
    /// `pending` is non-nil when the slot was left differing from the checkpoint; later writes are refused until resolved.
    case verifyFailed(rolledBack: Bool, underlying: KRError?, pending: PendingRecovery?)
    case outcomeUnknown(PendingRecovery, recordSaved: Bool)
}

extension SafeWriteError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .refused(let reason, let underlying):
            return "Write refused: \(reason)" + suffix(underlying)
        case .verifyFailed(let rolledBack, let underlying, let pending):
            let state = rolledBack ? "slot restored" : "slot not restored"
            let recovery = pending == nil ? "" : ", recovery pending"
            return "Verification failed, \(state)\(recovery)" + suffix(underlying)
        case .outcomeUnknown(let record, let recordSaved):
            let saved = recordSaved ? "recorded" : "record not saved"
            return "Write outcome unknown at step \(record.step.rawValue) (\(saved)): \(record.reason)"
        }
    }
    
    private func suffix(_ underlying: KRError?) -> String {
        underlying.map { " (\($0))" } ?? ""
    }
}
