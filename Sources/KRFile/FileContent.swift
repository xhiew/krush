//
//  FileContent.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

public struct FileContent: Equatable, Sendable {
    public let fid: UInt16
    public let flags: UInt8
    public let name: String
    public let data: [UInt8]
    
    public init(fid: UInt16, flags: UInt8, name: String, data: [UInt8]) {
        self.fid = fid
        self.flags = flags
        self.name = name
        self.data = data
    }
}
