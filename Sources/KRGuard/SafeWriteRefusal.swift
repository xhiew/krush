//
//  SafeWriteRefusal.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

public enum SafeWriteRefusal: Equatable, Sendable {
    case notConnected
    case halted
    case transferInterrupted
    case debugLoop
    case pendingRecovery
    case notSampleSlot
    case slotEmpty
    case slotOccupied
    case invalidName
    case invalidData
    case invalidMetadata
    case readOnlyKey
    case checkpointFailed
    case preflightFailed
}

extension SafeWriteRefusal: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notConnected: return "device is not connected"
        case .halted: return "device is halted; power-cycle required"
        case .transferInterrupted: return "a previous transfer was interrupted; power-cycle required"
        case .debugLoop: return "device is emitting debug frames; power-cycle required"
        case .pendingRecovery: return "a pending recovery must be resolved first"
        case .notSampleSlot: return "target is not a sample slot"
        case .slotEmpty: return "slot is empty"
        case .slotOccupied: return "slot is already occupied"
        case .invalidName: return "invalid sample name"
        case .invalidData: return "invalid sample data"
        case .invalidMetadata: return "invalid metadata JSON"
        case .readOnlyKey: return "metadata key is read-only"
        case .checkpointFailed: return "checkpoint could not be created"
        case .preflightFailed: return "device state could not be read"
        }
    }
}
