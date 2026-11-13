//
//  FileOpcodeTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
@testable import KRWire

struct FileOpcodeTests {
    private static let expected: [(name: String, opcode: FileOpcode, bytes: [UInt8])] = [
        ("initialize", .initialize, [0x01]),
        ("putOpen", .putOpen, [0x02, 0x00]),
        ("putData", .putData, [0x02, 0x01]),
        ("getOpen", .getOpen, [0x03, 0x00]),
        ("getData", .getData, [0x03, 0x01]),
        ("list", .list, [0x04]),
        ("play", .play, [0x05, 0x01]),
        ("delete", .delete, [0x06]),
        ("metadataSet", .metadataSet, [0x07, 0x01]),
        ("metadataGet", .metadataGet, [0x07, 0x02]),
        ("stat", .stat, [0x0B]),
    ]
    
    @Test func constantsMatchProtocolBytes() {
        for entry in Self.expected {
            #expect(entry.opcode.bytes == entry.bytes, "\(entry.name)")
        }
    }
    
    @Test func constantsAreDistinct() {
        let unique = Set(Self.expected.map(\.opcode))
        #expect(unique.count == Self.expected.count)
    }
    
    @Test func noDeleteWithSecondByte() {
        let all = Self.expected.map(\.opcode.bytes)
        #expect(!all.contains([0x06, 0x02]))
        #expect(FileOpcode.delete.bytes == [0x06])
    }
    
    @Test func productConstants() {
        #expect(Product.ep133.rawValue == 0x33)
        #expect(Product.ep40.rawValue == 0x3C)
        #expect(Product(rawValue: 0x41).rawValue == 0x41)
        #expect(Product(rawValue: 0x41) != .ep133)
    }
    
    @Test func sysExCommandRawValues() {
        #expect(SysExCommand.greet.rawValue == 0x01)
        #expect(SysExCommand.file.rawValue == 0x05)
    }
}
