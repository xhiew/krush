//
//  MIDIEventListTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
@testable import KRTransport

struct MIDIEventListTests {
    @Test(arguments: [0, 6, 7, 433, 600])
    func roundTripThroughEventList(bodyLength: Int) throws {
        let original = [0xF0] + (0..<bodyLength).map { UInt8($0 % 0x80) } + [0xF7]
        let words = try UMPSysEx7.encode(frame: original)
        let copied = try MIDIEventListWriter.withEventList(words: words) { list in
            CoreMIDITransport.copyWords(from: list)
        }
        #expect(copied == words)
        var decoder = UMPSysEx7.Decoder()
        #expect(decoder.feed(words: copied) == [original])
    }
}
