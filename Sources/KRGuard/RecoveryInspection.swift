//
//  RecoveryInspection.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

public enum SlotState: Equatable, Sendable {
    case absent
    case present(size: UInt32, nodeName: String, data: [UInt8]?, metadataJSON: String?)
}

public struct RecoveryInspection: Equatable, Sendable {
    public let record: PendingRecovery
    public let checkpoint: Checkpoint?
    public let current: SlotState
    
    public init(record: PendingRecovery, checkpoint: Checkpoint?, current: SlotState) {
        self.record = record
        self.checkpoint = checkpoint
        self.current = current
    }
}

public enum RecoveryResolution: Equatable, Sendable {
    case restore
    case keep
}
