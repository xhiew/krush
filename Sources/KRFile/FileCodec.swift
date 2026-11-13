//
//  FileCodec.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore
import KRWire

/// All multi-byte integers are big-endian.
/// Ref: ko2-io `src/fileclient.rs`.
enum FileCodec {
    static let defaultChunkSize = 512
    // Packed7 adds 1/7, so a 64 KiB chunk would exceed the transport's 64 KiB frame limit.
    static let maxChunkSize = 32_768
    
    private static let initResponseMinLength = 5
    private static let pageEchoLength = 2
    private static let entryHeaderLength = 7
    private static let statHeaderLength = 9
    
    static func initRequest(flags: UInt8, maxResponseLength: UInt32) -> [UInt8] {
        FileOpcode.initialize.bytes + [flags] + bigEndian(maxResponseLength)
    }
    
    static func chunkSize(initResponse payload: [UInt8]) -> Int {
        guard payload.count >= initResponseMinLength else { return defaultChunkSize }
        let size = Int(readUInt32(payload, at: 1))
        return size == 0 ? defaultChunkSize : min(size, maxChunkSize)
    }
    
    static func listRequest(page: UInt16, node: UInt16) -> [UInt8] {
        FileOpcode.list.bytes + bigEndian(page) + bigEndian(node)
    }
    
    /// `nil` marks the terminating page.
    static func listPage(_ payload: [UInt8], expectedPage: UInt16) throws(KRError) -> [FileNode]? {
        guard payload.count > pageEchoLength else { return nil }
        let echo = readUInt16(payload, at: 0)
        guard echo == expectedPage else {
            throw KRError.malformedResponse(reason: "list page \(echo), expected \(expectedPage)")
        }
        var nodes: [FileNode] = []
        var offset = pageEchoLength
        while payload.count - offset >= entryHeaderLength {
            let nameStart = offset + entryHeaderLength
            let nameEnd = payload[nameStart...].firstIndex(of: 0) ?? payload.count
            nodes.append(FileNode(
                id: readUInt16(payload, at: offset),
                flags: payload[offset + 2],
                size: readUInt32(payload, at: offset + 3),
                name: String(decoding: payload[nameStart..<nameEnd], as: UTF8.self)
            ))
            offset = nameEnd + 1
        }
        return nodes
    }
    
    static func statRequest(fid: UInt16) -> [UInt8] {
        FileOpcode.stat.bytes + bigEndian(fid)
    }
    
    static func stat(_ payload: [UInt8]) throws(KRError) -> FileStat {
        guard payload.count >= statHeaderLength else {
            throw KRError.malformedResponse(reason: "stat payload has \(payload.count) bytes")
        }
        let nameBytes = payload[statHeaderLength...].prefix { $0 != 0 }
        return FileStat(
            fid: readUInt16(payload, at: 0),
            parent: readUInt16(payload, at: 2),
            flags: payload[4],
            size: readUInt32(payload, at: 5),
            name: String(decoding: nameBytes, as: UTF8.self)
        )
    }
    
    private static func bigEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
    
    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    
    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
    
    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(readUInt16(bytes, at: offset)) << 16) | UInt32(readUInt16(bytes, at: offset + 2))
    }
}
