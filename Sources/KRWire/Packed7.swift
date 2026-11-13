//
//  Packed7.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore

/// Each group of up to 7 raw bytes → 1 flag byte + the bytes masked with `0x7F`.
/// Bit 0 of the flag byte belongs to the first byte of the group.
/// Ref: ep-series-sysex `docs/sysex-protocol.md:47-72`, ko2-io `src/sysex.rs:29-66`.
public enum Packed7 {
    private static let groupSize = 7
    
    public static func encodedCount(rawCount: Int) -> Int {
        rawCount + (rawCount + groupSize - 1) / groupSize
    }
    
    public static func encode(_ raw: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(encodedCount(rawCount: raw.count))
        var start = 0
        while start < raw.count {
            let end = min(start + groupSize, raw.count)
            var flags: UInt8 = 0
            for index in start..<end where raw[index] & 0x80 != 0 {
                flags |= 1 << UInt8(index - start)
            }
            output.append(flags)
            for index in start..<end {
                output.append(raw[index] & 0x7F)
            }
            start = end
        }
        return output
    }
    
    public static func decode(_ encoded: [UInt8]) throws(KRError) -> [UInt8] {
        for (offset, value) in encoded.enumerated() where value & 0x80 != 0 {
            throw KRError.invalidDataByte(offset: offset, value: value)
        }
        // A trailing lone flag byte and surplus flag bits are ignored, like the references.
        var output: [UInt8] = []
        output.reserveCapacity(encoded.count)
        var index = 0
        while index < encoded.count {
            let flags = encoded[index]
            let count = min(groupSize, encoded.count - index - 1)
            for bit in 0..<count {
                let high = (flags >> UInt8(bit)) & 1
                output.append(encoded[index + 1 + bit] | (high << 7))
            }
            index += 1 + groupSize
        }
        return output
    }
}
