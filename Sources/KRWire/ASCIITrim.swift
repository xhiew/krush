//
//  ASCIITrim.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

enum ASCIITrim {
    static let reasonSet: Set<UInt8> = [0x00, 0x20]
    
    // Intentionally narrower than the reference's Unicode trim (`sysex.rs:105`, `sysex.py:136-138`).
    static let debugSet: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x00]
    
    static func trim(_ bytes: ArraySlice<UInt8>, set: Set<UInt8>) -> ArraySlice<UInt8> {
        var start = bytes.startIndex
        var end = bytes.endIndex
        while start < end, set.contains(bytes[start]) {
            start += 1
        }
        while end > start, set.contains(bytes[end - 1]) {
            end -= 1
        }
        return bytes[start..<end]
    }
    
    static func string(_ bytes: [UInt8], set: Set<UInt8>) -> String {
        String(decoding: trim(bytes[...], set: set), as: UTF8.self)
    }
}
