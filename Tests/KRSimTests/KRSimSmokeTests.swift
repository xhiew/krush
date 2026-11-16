//
//  KRSimSmokeTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Testing
@testable import KRSim

struct KRSimSmokeTests {
    @Test func nodesCompareByValue() {
        let node = SimNode(fid: 1000, parent: 0, flags: 0x0E, name: "sounds")
        #expect(node == SimNode(fid: 1000, parent: 0, flags: 0x0E, name: "sounds"))
        #expect(node != SimNode(fid: 1000, parent: 0, flags: 0x0E, name: "sounds", data: [1]))
        #expect(node != SimNode(fid: 1000, parent: 0, flags: 0x0E, name: "sounds", metadata: ["a": "1"]))
    }
}
