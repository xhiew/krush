//
//  SafeWriterConfiguration.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

public struct SafeWriterConfiguration: Equatable, Sendable {
    public var maxNameLength: Int
    public var checkpointsPerSlot: Int
    
    public init(maxNameLength: Int = 16, checkpointsPerSlot: Int = 20) {
        self.maxNameLength = maxNameLength
        self.checkpointsPerSlot = checkpointsPerSlot
    }
}
