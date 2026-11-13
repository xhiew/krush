//
//  TestFrames.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRWire

enum TestFrames {
    static func response(
        product: Product = .ep133,
        id: UInt16,
        status: UInt8 = 0,
        raw: [UInt8] = []
    ) -> [UInt8] {
        let requestID = RequestID(id)
        var frame: [UInt8] = [0xF0]
        frame += SysExFrame.manufacturer
        frame.append(product.rawValue)
        frame.append(SysExFrame.protocolMarker)
        frame.append(SysExFrame.bitRequestIDAvailable | requestID.high5)
        frame.append(requestID.low7)
        frame.append(SysExCommand.file.rawValue)
        frame.append(status)
        frame += Packed7.encode(raw)
        frame.append(0xF7)
        return frame
    }
    
    static func debug(product: Product = .ep133, text: String) -> [UInt8] {
        var frame: [UInt8] = [0xF0]
        frame += SysExFrame.manufacturer
        frame.append(product.rawValue)
        frame.append(SysExFrame.debugMarker)
        frame += Array(text.utf8)
        frame.append(0xF7)
        return frame
    }
    
    static func requestID(of frame: [UInt8]) -> UInt16 {
        let high = UInt16(frame[SysExFrame.flagsIndex] & 0x1F)
        return (high << 7) | UInt16(frame[SysExFrame.idLowIndex])
    }
}
