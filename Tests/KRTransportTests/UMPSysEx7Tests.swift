//
//  UMPSysEx7Tests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
import KRCore
@testable import KRTransport

struct UMPSysEx7Tests {
    private let stat: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x45, 0x05, 0x00, 0x0B, 0x01, 0x02, 0xF7]
    
    private func frame(bodyLength: Int) -> [UInt8] {
        [0xF0] + (0..<bodyLength).map { UInt8($0 % 0x80) } + [0xF7]
    }
    
    private func statusAndCounts(_ words: [UInt32]) -> [(status: UInt32, count: UInt32)] {
        stride(from: 0, to: words.count, by: 2).map { (words[$0] >> 20 & 0xF, words[$0] >> 16 & 0xF) }
    }
    
    @Test func encodeStatFrame() throws {
        // start(6): 3|0|1|6 00 20 / 76 33 40 66; end(6): 3|0|3|6 45 05 / 00 0B 01 02
        #expect(try UMPSysEx7.encode(frame: stat) == [0x3016_0020, 0x7633_4066, 0x3036_4505, 0x000B_0102])
    }
    
    @Test func encodeGroupNibble() throws {
        #expect(try UMPSysEx7.encode(frame: [0xF0, 0xF7], group: 5) == [0x3500_0000, 0])
    }
    
    @Test func encodePacketStatuses() throws {
        let expected: [(Int, [UInt32], [UInt32])] = [
            (0, [0], [0]),
            (6, [0], [6]),
            (7, [1, 3], [6, 1]),
            (13, [1, 2, 3], [6, 6, 1])
        ]
        for (length, statuses, counts) in expected {
            let result = statusAndCounts(try UMPSysEx7.encode(frame: frame(bodyLength: length)))
            #expect(result.map(\.status) == statuses)
            #expect(result.map(\.count) == counts)
        }
    }
    
    @Test(arguments: [0, 1, 5, 6, 7, 12, 13, 18, 433, 600])
    func roundTrip(bodyLength: Int) throws {
        let original = frame(bodyLength: bodyLength)
        var decoder = UMPSysEx7.Decoder()
        #expect(decoder.feed(words: try UMPSysEx7.encode(frame: original)) == [original])
    }
    
    @Test func encodeRejectsMissingDelimiters() {
        #expect(throws: KRError.frameMissingDelimiters) { try UMPSysEx7.encode(frame: [0x01, 0xF7]) }
        #expect(throws: KRError.frameMissingDelimiters) { try UMPSysEx7.encode(frame: [0xF0, 0x01]) }
        #expect(throws: KRError.frameMissingDelimiters) { try UMPSysEx7.encode(frame: []) }
    }
    
    @Test func decodeIgnoresRealtimeAndChannelMessagesInsideFrame() throws {
        let words = try UMPSysEx7.encode(frame: stat)
        let clock: UInt32 = 0x10F8_0000
        let noteOn: UInt32 = 0x2090_3C7F
        var decoder = UMPSysEx7.Decoder()
        let mixed = Array(words[0..<2]) + [clock, noteOn] + Array(words[2...])
        #expect(decoder.feed(words: mixed) == [stat])
    }
    
    @Test func decodeContinueAndEndWithoutStartAreDropped() {
        var decoder = UMPSysEx7.Decoder()
        #expect(decoder.feed(words: [0x3026_0102, 0x0304_0506, 0x3036_0102, 0x0304_0506]).isEmpty)
    }
    
    @Test func decodeNewStartReplacesOldOne() throws {
        let words = try UMPSysEx7.encode(frame: stat)
        var decoder = UMPSysEx7.Decoder()
        #expect(decoder.feed(words: Array(words[0..<2]) + words) == [stat])
    }
    
    @Test func decodeInvalidCountAbortsFrame() throws {
        var decoder = UMPSysEx7.Decoder()
        let start: [UInt32] = [0x3016_0102, 0x0304_0506]
        let badContinue: [UInt32] = [0x3027_0102, 0x0304_0506]
        let end: [UInt32] = [0x3036_0102, 0x0304_0506]
        #expect(decoder.feed(words: start + badContinue + end).isEmpty)
        let valid = try UMPSysEx7.encode(frame: [0xF0, 0x01, 0xF7])
        #expect(decoder.feed(words: valid) == [[0xF0, 0x01, 0xF7]])
    }
    
    @Test func decodeInvalidStatusAbortsFrame() {
        var decoder = UMPSysEx7.Decoder()
        let start: [UInt32] = [0x3016_0102, 0x0304_0506]
        let badStatus: [UInt32] = [0x3046_0102, 0x0304_0506]
        let end: [UInt32] = [0x3036_0102, 0x0304_0506]
        #expect(decoder.feed(words: start + badStatus + end).isEmpty)
    }
    
    @Test func decodeDoesNotFilterByGroup() throws {
        let a: [UInt8] = [0xF0, 0x01, 0xF7]
        let b: [UInt8] = [0xF0, 0x02, 0xF7]
        var decoder = UMPSysEx7.Decoder()
        let words = try UMPSysEx7.encode(frame: a, group: 0) + UMPSysEx7.encode(frame: b, group: 5)
        #expect(decoder.feed(words: words) == [a, b])
    }
    
    @Test func decodeTruncatedPacketIsIgnored() {
        var decoder = UMPSysEx7.Decoder()
        #expect(decoder.feed(words: [0x3006_0102]).isEmpty)
        #expect(decoder.feed(words: []).isEmpty)
    }
    
    @Test(arguments: [0x3016_01F7 as UInt32, 0x3016_01F8, 0x3016_0180])
    func decodeDataByteWithHighBitAbortsFrame(word0: UInt32) throws {
        var decoder = UMPSysEx7.Decoder()
        let end: [UInt32] = [0x3036_0102, 0x0304_0506]
        #expect(decoder.feed(words: [word0, 0x0304_0506] + end).isEmpty)
        let valid = try UMPSysEx7.encode(frame: [0xF0, 0x01, 0xF7])
        #expect(decoder.feed(words: valid) == [[0xF0, 0x01, 0xF7]])
    }
    
    @Test func decodeIgnoresPaddingBeyondCount() {
        var decoder = UMPSysEx7.Decoder()
        #expect(decoder.feed(words: [0x3002_0102, 0xFFFF_FFFF]) == [[0xF0, 0x01, 0x02, 0xF7]])
    }
}
