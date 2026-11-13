//
//  RequestIDGeneratorTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
@testable import KRWire

struct RequestIDGeneratorTests {
    @Test(arguments: [
        (UInt16(0x1345), UInt16(0x345)),
        (UInt16(0xFFFF), UInt16(0xFFF)),
        (UInt16(0x1000), UInt16(0x000))
    ])
    func initStartIsMaskedTo12Bits(start: UInt16, expected: UInt16) {
        var generator = RequestIDGenerator(start: start)
        #expect(generator.next().value == expected)
    }
    
    @Test func maskedStartStillWrapsInsteadOfOverflowing() {
        var generator = RequestIDGenerator(start: 0xFFFF)
        #expect(generator.next().value == 0xFFF)
        #expect(generator.next().value == 0x000)
    }
    
    @Test func copiesAdvanceIndependently() {
        var a = RequestIDGenerator()
        _ = a.next()
        var b = a
        #expect(a.next() == b.next())
    }
    
    @Test func requestIDEqualityUsesMaskedValue() {
        #expect(RequestID(0x1345) == RequestID(0x345))
        #expect(RequestID(0x345) != RequestID(0x346))
    }
}
