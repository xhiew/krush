//
//  Packed7Tests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore
import Testing
@testable import KRWire

struct Packed7Tests {
    @Test(arguments: Packed7Fixtures.knownVectors)
    func encodeMatchesKnownVector(vector: Packed7Vector) {
        let encoded = Packed7.encode(vector.raw)
        #expect(encoded == vector.encoded)
        #expect(encoded.count == Packed7.encodedCount(rawCount: vector.raw.count))
        #expect(encoded.allSatisfy { $0 < 0x80 })
    }
    
    @Test(arguments: Packed7Fixtures.knownVectors)
    func decodeMatchesKnownVector(vector: Packed7Vector) throws {
        #expect(try Packed7.decode(vector.encoded) == vector.raw)
    }
    
    @Test(arguments: [(0, 0), (1, 2), (7, 8), (8, 10), (14, 16), (15, 18)])
    func encodedCountFormula(rawCount: Int, expected: Int) {
        #expect(Packed7.encodedCount(rawCount: rawCount) == expected)
    }
    
    @Test(arguments: Packed7Fixtures.roundTripRaws)
    func roundTripFixedInputs(raw: [UInt8]) throws {
        #expect(try Packed7.decode(Packed7.encode(raw)) == raw)
    }
    
    @Test(arguments: Packed7Fixtures.randomLengths)
    func roundTripRandomLengths(length: Int) throws {
        var generator = SeededGenerator(seed: UInt64(length) &* 0x1234_5678_9ABC)
        let raw = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let encoded = Packed7.encode(raw)
        #expect(encoded.count == Packed7.encodedCount(rawCount: length))
        #expect(encoded.allSatisfy { $0 < 0x80 })
        #expect(try Packed7.decode(encoded) == raw)
    }
    
    @Test(arguments: 1...6)
    func decodeShortLastGroup(lastGroupCount: Int) throws {
        // A full group followed by a last group of `lastGroupCount` bytes (1...6).
        let raw = [UInt8](repeating: 0x81, count: 7) + [UInt8](repeating: 0xC0, count: lastGroupCount)
        #expect(try Packed7.decode(Packed7.encode(raw)) == raw)
    }
    
    @Test
    func decodeLoneFlagByteGivesEmpty() throws {
        #expect(try Packed7.decode([0x00]) == [])
        #expect(try Packed7.decode([0x7F]) == [])
    }
    
    @Test
    func decodeIgnoresTrailingLoneFlagAfterFullGroup() throws {
        let encoded = Packed7.encode([UInt8](repeating: 0xFF, count: 7)) + [0x55]
        #expect(try Packed7.decode(encoded) == [UInt8](repeating: 0xFF, count: 7))
    }
    
    @Test
    func decodeIgnoresSurplusFlagBits() throws {
        // Last group has one data byte but flag bits 0 and 6 set; only bit 0 applies.
        #expect(try Packed7.decode([0x41, 0x05]) == [0x85])
    }
    
    @Test
    func decodeRejectsHighBit() {
        #expect(throws: KRError.invalidDataByte(offset: 2, value: 0x80)) {
            try Packed7.decode([0x00, 0x41, 0x80])
        }
    }
    
    @Test
    func decodeRejectsHighBitInFlagByte() {
        #expect(throws: KRError.invalidDataByte(offset: 0, value: 0x80)) {
            try Packed7.decode([0x80, 0x01])
        }
    }
}
