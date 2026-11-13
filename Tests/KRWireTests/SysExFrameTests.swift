//
//  SysExFrameTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore
import Testing
@testable import KRWire

struct SysExFrameTests {
    @Test(arguments: FrameFixtures.requestVectors)
    func buildsRequestByteExact(vector: RequestVector) {
        let frame = SysExFrame.fileRequest(
            product: vector.product,
            id: RequestID(vector.id),
            payload: vector.payload
        )
        #expect(frame == vector.frame)
    }
    
    @Test(arguments: FrameFixtures.requestVectors)
    func parsesRequestVectors(vector: RequestVector) throws {
        let parsed = try SysExFrame.parse(vector.frame)
        #expect(parsed == .request(FileRequest(
            product: vector.product,
            id: RequestID(vector.id),
            command: SysExCommand.file.rawValue,
            payload: vector.payload
        )))
    }
    
    @Test(arguments: [UInt16(0x000), 0x300, 0xFFF], [0, 1, 7, 8, 433])
    func roundTripsRequests(id: UInt16, length: Int) throws {
        var generator = SeededGenerator(seed: UInt64(id) &* 1000 &+ UInt64(length))
        let payload = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let frame = SysExFrame.fileRequest(product: .ep133, id: RequestID(id), payload: payload)
        #expect(frame.dropFirst().dropLast().allSatisfy { $0 < 0x80 })
        #expect(frame.first == 0xF0)
        #expect(frame.last == 0xF7)
        let parsed = try SysExFrame.parse(frame)
        #expect(parsed == .request(FileRequest(
            product: .ep133,
            id: RequestID(id),
            command: SysExCommand.file.rawValue,
            payload: payload
        )))
    }
    
    @Test func parsesEmptyPayloadRequest() throws {
        let parsed = try SysExFrame.parse(FrameFixtures.emptyRequestFrame)
        #expect(parsed == .request(FileRequest(
            product: .ep133,
            id: RequestID(0x345),
            command: 0x05,
            payload: []
        )))
    }
    
    @Test(arguments: FrameFixtures.malformedVectors)
    func handlesMalformedFrames(vector: MalformedVector) {
        if let expected = vector.error {
            #expect(throws: expected) {
                try SysExFrame.parse(vector.frame)
            }
        } else {
            #expect(throws: Never.self) {
                let parsed = try SysExFrame.parse(vector.frame)
                #expect(parsed == .unrelated)
            }
        }
    }
    
    /// Prefixes closed with `F7` pass the delimiter guard and reach the length checks.
    @Test func everyTerminatedPrefixOfAValidFrameGivesExpectedResult() throws {
        let frame = FrameFixtures.requestVectors[0].frame
        for length in 1..<frame.count {
            let candidate = Array(frame.prefix(length)) + [0xF7]
            switch candidate.count {
            case ...4:
                #expect(try SysExFrame.parse(candidate) == .unrelated, "count \(candidate.count)")
            case 5...9:
                #expect(
                    throws: KRError.frameTooShort(length: candidate.count),
                    "count \(candidate.count)"
                ) {
                    try SysExFrame.parse(candidate)
                }
            default:
                guard case .request = try SysExFrame.parse(candidate) else {
                    Issue.record("count \(candidate.count) not parsed as request")
                    continue
                }
            }
        }
    }
    
    @Test func shortManufacturerPrefixes() throws {
        #expect(try SysExFrame.parse([0xF0, 0x00, 0x20, 0xF7]) == .unrelated)
        #expect(throws: KRError.frameTooShort(length: 5)) {
            try SysExFrame.parse([0xF0, 0x00, 0x20, 0x76, 0xF7])
        }
    }
    
    @Test func markerWithoutFlagsIsTooShort() {
        #expect(throws: KRError.frameTooShort(length: 7)) {
            try SysExFrame.parse([0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0xF7])
        }
    }
    
    @Test func dataByteScanRunsBeforeDebugClassification() {
        #expect(throws: KRError.invalidDataByte(offset: 6, value: 0xC3)) {
            try SysExFrame.parse([0xF0, 0x00, 0x20, 0x76, 0x33, 0x33, 0xC3, 0xF7])
        }
    }
}
