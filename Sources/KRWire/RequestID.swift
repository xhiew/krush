public struct RequestID: Hashable, Sendable {
    public let value: UInt16
    
    public init(_ raw: UInt16) {
        value = raw & 0x0FFF
    }
    
    public var high5: UInt8 {
        UInt8((value >> 7) & 0x1F)
    }
    
    public var low7: UInt8 {
        UInt8(value & 0x7F)
    }
}
