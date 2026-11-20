//
//  Checkpoint.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation

public struct Checkpoint: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case put
        case replace
        case delete
        case setMetadata
        case restore
    }
    
    public struct PriorSlot: Codable, Equatable, Sendable {
        public let nodeName: String
        public let flags: UInt8
        public let size: UInt32
        /// `nil` for metadata operations and for restore checkpoints taken without data.
        public let data: Data?
        public let metadataJSON: String
        
        public init(nodeName: String, flags: UInt8, size: UInt32, data: Data?, metadataJSON: String) {
            self.nodeName = nodeName
            self.flags = flags
            self.size = size
            self.data = data
            self.metadataJSON = metadataJSON
        }
    }
    
    public let version: Int
    public let id: UUID
    public let fid: UInt16
    public let operation: Operation
    public let createdAt: Date
    /// `nil` means the slot was empty.
    public let prior: PriorSlot?
    public let writtenKeys: [String]?
    public let expectedSize: UInt32?
    public let restoreMetadataParts: [String]?
    
    public var slotWasEmpty: Bool { prior == nil }
    
    public init(
        version: Int = 1,
        id: UUID = UUID(),
        fid: UInt16,
        operation: Operation,
        createdAt: Date = Date(),
        prior: PriorSlot?,
        writtenKeys: [String]? = nil,
        expectedSize: UInt32? = nil,
        restoreMetadataParts: [String]? = nil
    ) {
        self.version = version
        self.id = id
        self.fid = fid
        self.operation = operation
        self.createdAt = createdAt
        self.prior = prior
        self.writtenKeys = writtenKeys
        self.expectedSize = expectedSize
        self.restoreMetadataParts = restoreMetadataParts
    }
}
