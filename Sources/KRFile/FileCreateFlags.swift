//
//  FileCreateFlags.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

public struct FileCreateFlags: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
    
    public static let sound = FileCreateFlags(rawValue: 0x05)
    public static let projectArchive = FileCreateFlags(rawValue: 0x06)
}
