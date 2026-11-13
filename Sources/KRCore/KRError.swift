public enum KRError: Error, Equatable, Sendable {
    case frameMissingDelimiters
    
    case frameTooShort(length: Int)
    
    /// `offset` is relative to the input of the throwing function: frame index
    /// for `SysExFrame.parse`, encoded-array index for `Packed7.decode`.
    case invalidDataByte(offset: Int, value: UInt8)
    
    case statusRejected(status: UInt8, reason: String)
    
    case deviceDebugFrame(text: String)
}

extension KRError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .frameMissingDelimiters:
            return "SysEx frame is missing the F0 start or F7 end delimiter"
        case .frameTooShort(let length):
            return "SysEx frame is too short (\(length) bytes)"
        case .invalidDataByte(let offset, let value):
            return "Invalid data byte \(hex(value)) at offset \(offset)"
        case .statusRejected(let status, let reason):
            return "Device rejected the request with status \(hex(status)): \(reason)"
        case .deviceDebugFrame(let text):
            return "Device debug frame: \(text)"
        }
    }
}

private func hex(_ value: UInt8) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    return "0x" + (digits.count < 2 ? "0" + digits : digits)
}
