//
//  KRError.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

public enum KRError: Error, Equatable, Sendable {
    case frameMissingDelimiters
    
    case frameTooShort(length: Int)
    
    /// `offset` is relative to the input of the throwing function: frame index
    /// for `SysExFrame.parse`, encoded-array index for `Packed7.decode`.
    case invalidDataByte(offset: Int, value: UInt8)
    
    case statusRejected(status: UInt8, reason: String)
    
    case deviceDebugFrame(text: String)
    
    case timeout(requestID: UInt16)
    
    case disconnected
    
    case alreadyConnected
    
    case cancelled
    
    case deviceNotFound
    
    /// `status` is a non-`noErr` `OSStatus`; only for genuine CoreMIDI failures.
    case transportFailure(operation: String, status: Int32)
    
    case malformedResponse(reason: String)
    
    case invalidArgument(reason: String)
    
    /// A GET/PUT was cut short; the device must be power-cycled before the next write.
    case transferInterrupted
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
        case .timeout(let requestID):
            return "Request \(hex(requestID)) timed out"
        case .disconnected:
            return "Transport is not connected"
        case .alreadyConnected:
            return "Transport is already connected"
        case .cancelled:
            return "Operation was cancelled"
        case .deviceNotFound:
            return "No matching device was found"
        case .transportFailure(let operation, let status):
            return "\(operation) failed with status \(status)"
        case .malformedResponse(let reason):
            return "Malformed response: \(reason)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .transferInterrupted:
            return "A previous transfer was interrupted; power-cycle the device before the next write"
        }
    }
}

private func hex(_ value: UInt8) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    return "0x" + (digits.count < 2 ? "0" + digits : digits)
}

private func hex(_ value: UInt16) -> String {
    "0x" + String(value, radix: 16, uppercase: true)
}
