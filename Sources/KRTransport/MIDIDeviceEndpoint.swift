//
//  MIDIDeviceEndpoint.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRWire

/// `sourceID` and `destinationID` are `kMIDIPropertyUniqueID` values.
public struct MIDIDeviceEndpoint: Hashable, Sendable, Identifiable {
    public let name: String
    public let product: Product
    public let sourceID: Int32
    public let destinationID: Int32
    
    public var id: Int32 { sourceID }
    
    public init(name: String, product: Product, sourceID: Int32, destinationID: Int32) {
        self.name = name
        self.product = product
        self.sourceID = sourceID
        self.destinationID = destinationID
    }
}
