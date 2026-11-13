//
//  EndpointCandidate.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

struct EndpointCandidate: Sendable {
    let uniqueID: Int32
    let name: String
    let entityID: Int32?
    let deviceID: Int32?
    let isOffline: Bool
}
