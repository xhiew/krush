//
//  SimNode.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

public struct SimNode: Equatable, Sendable {
    public var fid: UInt16
    public var parent: UInt16
    public var flags: UInt8
    public var name: String
    public var data: [UInt8]
    /// Key to raw JSON text of the value.
    public var metadata: [String: String]
    
    public init(
        fid: UInt16,
        parent: UInt16,
        flags: UInt8,
        name: String,
        data: [UInt8] = [],
        metadata: [String: String] = [:]
    ) {
        self.fid = fid
        self.parent = parent
        self.flags = flags
        self.name = name
        self.data = data
        self.metadata = metadata
    }
}
