//
//  SampleMetadata.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

public struct SampleMetadata: Equatable, Sendable {
    public let name: String
    public let channels: UInt8
    public let samplerate: UInt32
    
    public init(name: String, channels: UInt8, samplerate: UInt32 = 46875) {
        self.name = name
        self.channels = channels
        self.samplerate = samplerate
    }
}
