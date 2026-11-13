//
//  EndpointMatcherTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
import KRWire
@testable import KRTransport

struct EndpointMatcherTests {
    private func candidate(
        _ id: Int32,
        _ name: String,
        entity: Int32? = nil,
        device: Int32? = nil,
        offline: Bool = false
    ) -> EndpointCandidate {
        EndpointCandidate(uniqueID: id, name: name, entityID: entity, deviceID: device, isOffline: offline)
    }
    
    @Test(arguments: ["EP-133", "ep-133 K.O. II", "KO II", "K.O. II MIDI"])
    func ep133Names(name: String) {
        #expect(EndpointMatcher.product(forName: name) == .ep133)
    }
    
    @Test(arguments: ["EP-40", "EP-40 Riddim"])
    func ep40Names(name: String) {
        #expect(EndpointMatcher.product(forName: name) == .ep40)
    }
    
    @Test(arguments: ["IAC Driver", "", "EP-1320"])
    func unknownNames(name: String) {
        #expect(EndpointMatcher.product(forName: name) == nil)
    }
    
    @Test func pairsSameEntity() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133", entity: 10)],
            destinations: [candidate(2, "EP-133", entity: 10)]
        )
        #expect(result == [MIDIDeviceEndpoint(name: "EP-133", product: .ep133, sourceID: 1, destinationID: 2)])
    }
    
    @Test func pairsTwoProducts() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133", entity: 10), candidate(3, "EP-40", entity: 20)],
            destinations: [candidate(2, "EP-133", entity: 10), candidate(4, "EP-40", entity: 20)]
        )
        #expect(result.map(\.product) == [.ep133, .ep40])
        #expect(result.map(\.destinationID) == [2, 4])
    }
    
    @Test func dropsSourceWithoutDestination() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133", entity: 10)],
            destinations: []
        )
        #expect(result.isEmpty)
    }
    
    @Test func dropsUnknownName() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "IAC Driver", entity: 10)],
            destinations: [candidate(2, "IAC Driver", entity: 10)]
        )
        #expect(result.isEmpty)
    }
    
    @Test func dropsOfflineSource() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133", entity: 10, offline: true)],
            destinations: [candidate(2, "EP-133", entity: 10)]
        )
        #expect(result.isEmpty)
    }
    
    @Test func dropsOfflineDestination() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133", entity: 10)],
            destinations: [candidate(2, "EP-133", entity: 10, offline: true)]
        )
        #expect(result.isEmpty)
    }
    
    @Test func pairsByEntityNotAcrossSameDevice() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133 A", entity: 10, device: 100), candidate(3, "EP-133 B", entity: 20, device: 100)],
            destinations: [candidate(4, "EP-133 B", entity: 20, device: 100), candidate(2, "EP-133 A", entity: 10, device: 100)]
        )
        #expect(result.map(\.sourceID) == [1, 3])
        #expect(result.map(\.destinationID) == [2, 4])
    }
    
    @Test func fallsBackToDeviceThenName() {
        let byDevice = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133", device: 100)],
            destinations: [candidate(2, "Other", device: 100)]
        )
        #expect(byDevice.map(\.destinationID) == [2])
        let byName = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133")],
            destinations: [candidate(2, "EP-133")]
        )
        #expect(byName.map(\.destinationID) == [2])
    }
    
    @Test func sameNameDevicesDoNotPairAcrossWhenDestinationOffline() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133", entity: 10, device: 100), candidate(3, "EP-133", entity: 20, device: 200)],
            destinations: [candidate(2, "EP-133", entity: 10, device: 100, offline: true), candidate(4, "EP-133", entity: 20, device: 200)]
        )
        #expect(result == [MIDIDeviceEndpoint(name: "EP-133", product: .ep133, sourceID: 3, destinationID: 4)])
    }
    
    @Test func sameNameWithMismatchedDeviceIsNotPaired() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133", entity: 10, device: 100)],
            destinations: [candidate(2, "EP-133", entity: 20, device: 200)]
        )
        #expect(result.isEmpty)
    }
    
    @Test func destinationIsUsedOnce() {
        let result = EndpointMatcher.pair(
            sources: [candidate(1, "EP-133"), candidate(3, "EP-133")],
            destinations: [candidate(2, "EP-133")]
        )
        #expect(result.count == 1)
        #expect(result.map(\.destinationID) == [2])
    }
}
