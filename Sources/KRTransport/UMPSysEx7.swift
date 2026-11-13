//
//  UMPSysEx7.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore

/// Ref: MIDI 2.0 UMP spec §4.4. Word 0: `mt group status count d0 d1`; word 1: `d2 d3 d4 d5`.
enum UMPSysEx7 {
    private static let messageType: UInt32 = 0x3
    private static let maxBytesPerPacket = 6
    private static let frameStart: UInt8 = 0xF0
    private static let frameEnd: UInt8 = 0xF7
    
    private enum Status: UInt32 {
        case complete = 0
        case start = 1
        case `continue` = 2
        case end = 3
    }
    
    static func encode(frame: [UInt8], group: UInt8 = 0) throws(KRError) -> [UInt32] {
        guard frame.count >= 2, frame.first == frameStart, frame.last == frameEnd else {
            throw .frameMissingDelimiters
        }
        let body = frame[1..<(frame.count - 1)]
        let packetCount = max(1, (body.count + maxBytesPerPacket - 1) / maxBytesPerPacket)
        var words: [UInt32] = []
        words.reserveCapacity(packetCount * 2)
        let header = messageType << 28 | UInt32(group & 0xF) << 24
        var index = body.startIndex
        for packet in 0..<packetCount {
            let chunk = body[index..<min(index + maxBytesPerPacket, body.endIndex)]
            index = chunk.endIndex
            let status: Status
            if packetCount == 1 {
                status = .complete
            } else if packet == 0 {
                status = .start
            } else if packet == packetCount - 1 {
                status = .end
            } else {
                status = .continue
            }
            var data: [UInt32] = chunk.map { UInt32($0) }
            data.append(contentsOf: repeatElement(0, count: maxBytesPerPacket - data.count))
            words.append(header | status.rawValue << 20 | UInt32(chunk.count) << 16 | data[0] << 8 | data[1])
            words.append(data[2] << 24 | data[3] << 16 | data[4] << 8 | data[5])
        }
        return words
    }
    
    struct Decoder: Sendable {
        private var assembler = SysExAssembler()
        
        init() {}
        
        mutating func feed(words: [UInt32]) -> [[UInt8]] {
            var frames: [[UInt8]] = []
            var index = 0
            while index < words.count {
                let word = words[index]
                let type = word >> 28
                let length = Self.wordCount(forMessageType: type)
                guard index + length <= words.count else { break }
                if type == UMPSysEx7.messageType {
                    frames += decodePacket(word0: word, word1: words[index + 1])
                }
                index += length
            }
            return frames
        }
        
        private mutating func decodePacket(word0: UInt32, word1: UInt32) -> [[UInt8]] {
            let count = Int((word0 >> 16) & 0xF)
            guard let status = Status(rawValue: (word0 >> 20) & 0xF), count <= UMPSysEx7.maxBytesPerPacket else {
                assembler.abort()
                return []
            }
            let all = [word0 >> 8, word0, word1 >> 24, word1 >> 16, word1 >> 8, word1].map { UInt8(truncatingIfNeeded: $0) }
            guard !all.prefix(count).contains(where: { $0 >= 0x80 }) else {
                assembler.abort()
                return []
            }
            var bytes: [UInt8] = []
            if status == .complete || status == .start {
                bytes.append(UMPSysEx7.frameStart)
            }
            bytes.append(contentsOf: all.prefix(count))
            if status == .complete || status == .end {
                bytes.append(UMPSysEx7.frameEnd)
            }
            return assembler.feed(bytes)
        }
        
        private static func wordCount(forMessageType type: UInt32) -> Int {
            switch type {
            case 0x0, 0x1, 0x2, 0x6, 0x7: 1
            case 0x3, 0x4, 0x8, 0x9, 0xA: 2
            case 0xB, 0xC: 3
            case 0x5, 0xD, 0xE, 0xF: 4
            default: 1
            }
        }
    }
}
