//
//  FileStat.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

public struct FileStat: Equatable, Sendable {
    public let fid: UInt16
    public let parent: UInt16
    public let flags: UInt8
    public let size: UInt32
    public let name: String
    
    public init(fid: UInt16, parent: UInt16, flags: UInt8, size: UInt32, name: String) {
        self.fid = fid
        self.parent = parent
        self.flags = flags
        self.size = size
        self.name = name
    }
}
