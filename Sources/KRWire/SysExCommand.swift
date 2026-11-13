//
//  SysExCommand.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

public enum SysExCommand: UInt8, Sendable {
    case greet = 0x01
    case file = 0x05
}
