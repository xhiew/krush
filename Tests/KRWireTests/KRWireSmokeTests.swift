//
//  KRWireSmokeTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
@testable import KRWire

struct KRWireSmokeTests {
    @Test func moduleIsImportable() {
        _ = KRWire.self
    }
}
