//
//  FileNode.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

public struct FileNode: Equatable, Sendable {
    public static let rootID: UInt16 = 0
    public static let soundsID: UInt16 = 1000
    public static let projectsID: UInt16 = 2000
    
    public let id: UInt16
    public let flags: UInt8
    public let size: UInt32
    public let name: String
    
    public init(id: UInt16, flags: UInt8, size: UInt32, name: String) {
        self.id = id
        self.flags = flags
        self.size = size
        self.name = name
    }
}
