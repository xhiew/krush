//
//  SysExAssemblerTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
@testable import KRTransport

struct SysExAssemblerTests {
    private let stat: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x45, 0x05, 0x00, 0x0B, 0x01, 0x02, 0xF7]
    
    @Test func wholeFrameInOneFeed() {
        var assembler = SysExAssembler()
        #expect(assembler.feed(stat) == [stat])
    }
    
    @Test func byteByByteEmitsOnLastByte() {
        var assembler = SysExAssembler()
        var emitted: [[UInt8]] = []
        for (index, byte) in stat.enumerated() {
            let frames = assembler.feed([byte])
            if index < stat.count - 1 {
                #expect(frames.isEmpty)
            }
            emitted += frames
        }
        #expect(emitted == [stat])
    }
    
    @Test func splitFiveAndNine() {
        var assembler = SysExAssembler()
        #expect(assembler.feed(stat[0..<5]).isEmpty)
        #expect(assembler.feed(stat[5...]) == [stat])
    }
    
    @Test func realtimeInterleavedIsFiltered() {
        var assembler = SysExAssembler()
        var bytes = stat
        bytes.insert(0xFE, at: 10)
        bytes.insert(0xF8, at: 4)
        #expect(assembler.feed(bytes) == [stat])
    }
    
    @Test(arguments: [UInt8(0xFF), 0xFA, 0xFC])
    func otherRealtimeIsFiltered(realtime: UInt8) {
        var assembler = SysExAssembler()
        var bytes = stat
        bytes.insert(realtime, at: 6)
        #expect(assembler.feed(bytes) == [stat])
    }
    
    @Test func channelStatusAbortsFrame() {
        var assembler = SysExAssembler()
        #expect(assembler.feed([0xF0, 0x00, 0x20, 0x90, 0x3C, 0x7F, 0x01, 0xF7]).isEmpty)
        #expect(assembler.feed(stat) == [stat])
    }
    
    @Test func orphanEndIsIgnored() {
        var assembler = SysExAssembler()
        #expect(assembler.feed([0x00, 0x20, 0xF7]).isEmpty)
    }
    
    @Test func trailingFragmentWithoutStartIsDropped() {
        var assembler = SysExAssembler()
        let fragment: [UInt8] = [0x05, 0x00, 0x0B, 0xF7]
        #expect(assembler.feed(stat + fragment) == [stat])
    }
    
    @Test func startInsideFrameResetsBuffer() {
        var assembler = SysExAssembler()
        #expect(assembler.feed([0xF0, 0x01, 0xF0, 0x02, 0xF7]) == [[0xF0, 0x02, 0xF7]])
    }
    
    @Test func twoFramesInOneFeedKeepOrder() {
        var assembler = SysExAssembler()
        let other: [UInt8] = [0xF0, 0x01, 0xF7]
        #expect(assembler.feed(stat + other) == [stat, other])
    }
    
    @Test func dataBeforeStartIsDropped() {
        var assembler = SysExAssembler()
        #expect(assembler.feed([0x11, 0x22] + stat) == [stat])
    }
    
    @Test func overflowDropsFrameAndRecovers() {
        var assembler = SysExAssembler(maxFrameLength: 8)
        #expect(assembler.feed([0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 0xF7]).isEmpty)
        let fits: [UInt8] = [0xF0, 1, 2, 3, 4, 5, 6, 0xF7]
        #expect(assembler.feed(fits) == [fits])
    }
    
    @Test func emptyBodyFrame() {
        var assembler = SysExAssembler()
        #expect(assembler.feed([0xF0, 0xF7]) == [[0xF0, 0xF7]])
    }
    
    @Test func abortDiscardsPartialFrame() {
        var assembler = SysExAssembler()
        #expect(assembler.feed([0xF0, 0x01, 0x02]).isEmpty)
        assembler.abort()
        #expect(assembler.feed([0x03, 0xF7]).isEmpty)
    }
}
