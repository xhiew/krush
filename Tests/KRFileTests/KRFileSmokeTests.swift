//
//  KRFileSmokeTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
@testable import KRFile

struct KRFileSmokeTests {
    @Test func nodeConstants() {
        #expect(FileNode.rootID == 0)
        #expect(FileNode.soundsID == 1000)
        #expect(FileNode.projectsID == 2000)
    }
}
