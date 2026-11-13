//
//  EndpointMatcher.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRWire

/// Ref: ep-series-sysex `fileclient.py:64-67`.
enum EndpointMatcher {
    private static let ep133Hints = ["ep-133", "ko ii", "k.o. ii"]
    private static let ep40Hints = ["ep-40"]
    
    static func product(forName name: String) -> Product? {
        let lowered = name.lowercased()
        if ep133Hints.contains(where: { lowered.contains($0) }) {
            return .ep133
        }
        if ep40Hints.contains(where: { lowered.contains($0) }) {
            return .ep40
        }
        return nil
    }
    
    static func pair(
        sources: [EndpointCandidate],
        destinations: [EndpointCandidate]
    ) -> [MIDIDeviceEndpoint] {
        let liveSources = sources.filter { !$0.isOffline }
        var remaining = destinations.filter { !$0.isOffline }
        var matches: [Int: EndpointCandidate] = [:]
        let tiers: [(EndpointCandidate, EndpointCandidate) -> Bool] = [
            { source, destination in
                source.entityID != nil && source.entityID == destination.entityID
            },
            { source, destination in
                source.deviceID != nil && source.deviceID == destination.deviceID
                    && (source.entityID == nil || destination.entityID == nil)
            },
            { source, destination in
                source.name == destination.name
                    && compatible(source.entityID, destination.entityID)
                    && compatible(source.deviceID, destination.deviceID)
            }
        ]
        for isMatch in tiers {
            for (index, source) in liveSources.enumerated() where matches[index] == nil {
                guard product(forName: source.name) != nil,
                      let position = remaining.firstIndex(where: { isMatch(source, $0) })
                else { continue }
                matches[index] = remaining.remove(at: position)
            }
        }
        let endpoints = matches.compactMap { index, destination -> MIDIDeviceEndpoint? in
            let source = liveSources[index]
            guard let product = product(forName: source.name) else { return nil }
            return MIDIDeviceEndpoint(
                name: source.name,
                product: product,
                sourceID: source.uniqueID,
                destinationID: destination.uniqueID
            )
        }
        return endpoints.sorted {
            $0.name == $1.name ? $0.sourceID < $1.sourceID : $0.name < $1.name
        }
    }
    
    private static func compatible(_ lhs: Int32?, _ rhs: Int32?) -> Bool {
        lhs == nil || rhs == nil || lhs == rhs
    }
}
