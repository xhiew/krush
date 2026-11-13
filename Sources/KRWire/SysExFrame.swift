//
//  SysExFrame.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore

/// Indices are 0-based on the full frame including `F0`.
/// Ref: ep-series-sysex `docs/sysex-protocol.md`, ko2-io `src/sysex.rs`.
public enum SysExFrame {
    private static let startByte: UInt8 = 0xF0
    private static let endByte: UInt8 = 0xF7
    private static let dataLimit: UInt8 = 0x80
    
    public static let manufacturer: [UInt8] = [0x00, 0x20, 0x76]
    public static let productIndex = 4
    public static let markerIndex = 5
    public static let flagsIndex = 6
    public static let idLowIndex = 7
    public static let commandIndex = 8
    public static let statusIndex = 9
    
    public static let protocolMarker: UInt8 = 0x40
    public static let debugMarker: UInt8 = 0x33
    public static let bitIsRequest: UInt8 = 0x40
    public static let bitRequestIDAvailable: UInt8 = 0x20
    
    public static let minDebugLength = 7
    public static let minRequestLength = 10
    public static let minResponseLength = 11
    
    private static let requestPayloadIndex = statusIndex
    private static let responsePayloadIndex = statusIndex + 1
    
    public static func fileRequest(product: Product, id: RequestID, payload raw: [UInt8]) -> [UInt8] {
        let packed = Packed7.encode(raw)
        var frame: [UInt8] = []
        frame.reserveCapacity(minRequestLength + packed.count)
        frame.append(startByte)
        frame.append(contentsOf: manufacturer)
        frame.append(product.rawValue)
        frame.append(protocolMarker)
        frame.append(bitIsRequest | bitRequestIDAvailable | id.high5)
        frame.append(id.low7)
        frame.append(SysExCommand.file.rawValue)
        frame.append(contentsOf: packed)
        frame.append(endByte)
        return frame
    }
    
    /// Expects one complete `F0 … F7` frame with MIDI realtime bytes already
    /// filtered out by the transport. Non-TE SysEx is `.unrelated`.
    public static func parse(_ frame: [UInt8]) throws(KRError) -> ParsedFrame {
        guard frame.count >= 2, frame.first == startByte, frame.last == endByte else {
            throw KRError.frameMissingDelimiters
        }
        guard frame.count >= manufacturer.count + 1,
              Array(frame[1...manufacturer.count]) == manufacturer else {
            return .unrelated
        }
        guard frame.count >= minDebugLength else {
            throw KRError.frameTooShort(length: frame.count)
        }
        for index in 1..<(frame.count - 1) where frame[index] >= dataLimit {
            throw KRError.invalidDataByte(offset: index, value: frame[index])
        }
        let product = Product(rawValue: frame[productIndex])
        let marker = frame[markerIndex]
        // Debug frames reuse every product byte; detect by marker only.
        if marker == debugMarker {
            let text = ASCIITrim.string(
                Array(frame[flagsIndex..<(frame.count - 1)]),
                set: ASCIITrim.debugSet
            )
            return .debug(DebugFrame(product: product, text: text))
        }
        guard marker == protocolMarker else {
            return .unrelated
        }
        guard frame.count > flagsIndex + 1 else {
            throw KRError.frameTooShort(length: frame.count)
        }
        let flags = frame[flagsIndex]
        if flags & bitIsRequest != 0 {
            guard frame.count >= minRequestLength else {
                throw KRError.frameTooShort(length: frame.count)
            }
            let payload = try unpack(frame, from: requestPayloadIndex)
            return .request(FileRequest(
                product: product,
                id: requestID(frame),
                command: frame[commandIndex],
                payload: payload
            ))
        }
        if flags & (bitIsRequest | bitRequestIDAvailable) == bitRequestIDAvailable {
            guard frame.count >= minResponseLength else {
                throw KRError.frameTooShort(length: frame.count)
            }
            let payload = try unpack(frame, from: responsePayloadIndex)
            return .response(FileResponse(
                product: product,
                id: requestID(frame),
                command: frame[commandIndex],
                // Status is raw, outside the packed7 payload.
                status: frame[statusIndex],
                payload: payload
            ))
        }
        return .unrelated
    }
    
    private static func requestID(_ frame: [UInt8]) -> RequestID {
        let high = UInt16(frame[flagsIndex] & 0x1F)
        return RequestID((high << 7) | UInt16(frame[idLowIndex]))
    }
    
    private static func unpack(_ frame: [UInt8], from start: Int) throws(KRError) -> [UInt8] {
        do {
            return try Packed7.decode(Array(frame[start..<(frame.count - 1)]))
        } catch let error {
            if case .invalidDataByte(let offset, let value) = error {
                throw KRError.invalidDataByte(offset: offset + start, value: value)
            }
            throw error
        }
    }
}
