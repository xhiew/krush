//
//  PendingRecovery.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation

public enum WriteStep: String, Codable, Sendable {
    case delete
    case put
    case metadataSet
    case verify
    case rollback
}

public struct PendingRecovery: Codable, Equatable, Sendable {
    public let checkpointID: UUID
    public let fid: UInt16
    public let operation: Checkpoint.Operation
    public let step: WriteStep
    public let reason: String
    public let createdAt: Date
    
    public init(
        checkpointID: UUID,
        fid: UInt16,
        operation: Checkpoint.Operation,
        step: WriteStep,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.checkpointID = checkpointID
        self.fid = fid
        self.operation = operation
        self.step = step
        self.reason = reason
        self.createdAt = createdAt
    }
}
