//
//  SimBytes.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

enum SimBytes {
    static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
    
    static func be32(_ value: UInt32) -> [UInt8] {
        be16(UInt16(value >> 16)) + be16(UInt16(value & 0xFFFF))
    }
    
    static func u16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
    
    static func u32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard let high = u16(bytes, at: offset), let low = u16(bytes, at: offset + 2) else { return nil }
        return (UInt32(high) << 16) | UInt32(low)
    }
    
    /// Text up to the first NUL (or the end), starting at `offset`.
    static func cString(_ bytes: [UInt8], at offset: Int) -> String {
        guard offset >= 0, offset <= bytes.count else { return "" }
        let tail = bytes[offset...]
        let end = tail.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }
}
