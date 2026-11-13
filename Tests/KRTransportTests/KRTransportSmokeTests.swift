//
//  KRTransportSmokeTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
import KRWire
@testable import KRTransport

struct KRTransportSmokeTests {
    @Test func endpointIsHashableAndIdentifiedBySource() {
        let a = MIDIDeviceEndpoint(name: "EP-133", product: .ep133, sourceID: 10, destinationID: 11)
        let b = MIDIDeviceEndpoint(name: "EP-133", product: .ep133, sourceID: 10, destinationID: 11)
        let c = MIDIDeviceEndpoint(name: "EP-40", product: .ep40, sourceID: 20, destinationID: 21)
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
        #expect(a.id == 10)
    }
}
