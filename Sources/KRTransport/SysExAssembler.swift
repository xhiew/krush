//
//  SysExAssembler.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

/// Ref: ko2-io `src/midi.rs` (`feed`).
struct SysExAssembler: Sendable {
    private static let start: UInt8 = 0xF0
    private static let end: UInt8 = 0xF7
    private static let statusMin: UInt8 = 0x80
    private static let realtimeMin: UInt8 = 0xF8
    
    /// Counts delimiters. Overflowing frames are dropped so a lost `F7` cannot grow the buffer forever.
    let maxFrameLength: Int
    private var buffer: [UInt8] = []
    private var inFrame = false
    
    init(maxFrameLength: Int = 65_536) {
        self.maxFrameLength = maxFrameLength
    }
    
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for byte in bytes {
            switch byte {
            case Self.start:
                buffer.removeAll(keepingCapacity: true)
                buffer.append(byte)
                inFrame = true
            case Self.end:
                if inFrame {
                    buffer.append(byte)
                    frames.append(buffer)
                    abort()
                }
            case Self.realtimeMin...:
                break
            case Self.statusMin...:
                abort()
            default:
                guard inFrame else { continue }
                if buffer.count + 2 > maxFrameLength {
                    abort()
                } else {
                    buffer.append(byte)
                }
            }
        }
        return frames
    }
    
    mutating func abort() {
        buffer.removeAll(keepingCapacity: true)
        inFrame = false
    }
}
