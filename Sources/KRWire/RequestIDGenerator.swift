//
//  RequestIDGenerator.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

/// Wraps `0xFFF` → `0x000` (not back to `0x300`), like both references.
public struct RequestIDGenerator: Sendable {
    private var current: UInt16
    
    public init(start: UInt16 = 0x300) {
        current = start & 0x0FFF
    }
    
    public mutating func next() -> RequestID {
        let id = RequestID(current)
        current = (current + 1) & 0x0FFF
        return id
    }
}
