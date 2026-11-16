//
//  FileCodec+Transfer.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRCore
import KRWire

extension FileCodec {
    static let getPageBytes = 324
    static let putChunkFallback = 433
    
    private static let getOpenMinLength = 7
    private static let putOverheadBytes = 11
    private static let putHeaderBytes = 6
    
    static func getOpenRequest(fid: UInt16) -> [UInt8] {
        FileOpcode.getOpen.bytes + bigEndian(fid) + bigEndian(UInt32(0))
    }
    
    /// Layout: fid u16, flags u8, size u32, name, NUL.
    static func getOpen(
        _ payload: [UInt8],
        fid: UInt16
    ) throws(KRError) -> (flags: UInt8, size: UInt32, name: String) {
        guard payload.count >= getOpenMinLength else {
            throw KRError.malformedResponse(reason: "get open payload has \(payload.count) bytes")
        }
        let echo = readUInt16(payload, at: 0)
        guard echo == fid else {
            throw KRError.malformedResponse(reason: "get open echoed fid \(echo), expected \(fid)")
        }
        let nameBytes = payload[getOpenMinLength...].prefix { $0 != 0 }
        return (payload[2], readUInt32(payload, at: 3), String(decoding: nameBytes, as: UTF8.self))
    }
    
    static func getPageCount(size: UInt32) -> Int {
        (Int(size) + getPageBytes - 1) / getPageBytes
    }
    
    static func getDataRequest(page: UInt16) -> [UInt8] {
        FileOpcode.getData.bytes + bigEndian(page)
    }
    
    static func getDataPage(_ payload: [UInt8], expectedPage: UInt16) throws(KRError) -> ArraySlice<UInt8> {
        guard payload.count >= 2 else {
            throw KRError.malformedResponse(reason: "short data page \(expectedPage)")
        }
        let echo = readUInt16(payload, at: 0)
        guard echo == expectedPage else {
            throw KRError.malformedResponse(reason: "data page \(echo), expected \(expectedPage)")
        }
        return payload[2...]
    }
    
    static func putOpenRequest(
        flags: FileCreateFlags,
        fid: UInt16,
        parent: UInt16,
        size: UInt32,
        name: String,
        maxPayload: Int
    ) throws(KRError) -> [UInt8] {
        try validateText(name, field: "name")
        let request = FileOpcode.putOpen.bytes + [flags.rawValue] + bigEndian(fid) + bigEndian(parent)
            + bigEndian(size) + Array(name.utf8) + [0]
        guard request.count <= maxPayload else {
            throw KRError.invalidArgument(reason: "put open payload has \(request.count) bytes, limit \(maxPayload)")
        }
        return request
    }
    
    static func checkPutOpenEcho(_ payload: [UInt8], fid: UInt16) throws(KRError) {
        guard payload.count >= 2 else { return }
        let echo = readUInt16(payload, at: 0)
        guard echo == fid else {
            throw KRError.malformedResponse(reason: "put open echoed fid \(echo), expected \(fid)")
        }
    }
    
    /// Empty `bytes` is the EOF page.
    static func putDataRequest(page: UInt16, bytes: ArraySlice<UInt8>) -> [UInt8] {
        FileOpcode.putData.bytes + bigEndian(page) + bytes
    }
    
    /// Ref: ko2-io `src/fileclient.rs:131-141`.
    static func putPayloadBytes(chunkSize: Int) -> Int {
        let usable = chunkSize - putHeaderBytes
        guard usable > putOverheadBytes else { return putChunkFallback }
        let available = usable - 1 - putOverheadBytes
        return max(1, available - available / 8)
    }
    
    static func deleteRequest(fid: UInt16) -> [UInt8] {
        FileOpcode.delete.bytes + bigEndian(fid)
    }
    
    static func playRequest(fid: UInt16) -> [UInt8] {
        FileOpcode.play.bytes + bigEndian(fid)
    }
}
