//
//  FileCodec+Metadata.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRCore
import KRWire

extension FileCodec {
    private static let metadataEchoLength = 2
    
    static func metadataGetRequest(fid: UInt16, page: UInt16, key: String?) throws(KRError) -> [UInt8] {
        var request = FileOpcode.metadataGet.bytes + bigEndian(fid) + bigEndian(page)
        if let key {
            try validateText(key, field: "key")
            request += Array(key.utf8) + [0]
        }
        return request
    }
    
    /// `nil` marks the terminating page.
    static func metadataPage(
        _ payload: [UInt8],
        expectedPage: UInt16
    ) throws(KRError) -> (text: String, isLast: Bool)? {
        guard payload.count > metadataEchoLength else { return nil }
        let echo = readUInt16(payload, at: 0)
        guard echo == expectedPage else {
            throw KRError.malformedResponse(reason: "metadata page \(echo), expected \(expectedPage)")
        }
        let textBytes = payload[metadataEchoLength...].prefix { $0 != 0 }
        return (String(decoding: textBytes, as: UTF8.self), payload[payload.count - 1] == 0)
    }
    
    static func metadataSetRequest(fid: UInt16, json: String, maxPayload: Int) throws(KRError) -> [UInt8] {
        guard !json.isEmpty else {
            throw KRError.invalidArgument(reason: "json is empty")
        }
        guard !json.utf8.contains(0) else {
            throw KRError.invalidArgument(reason: "json contains NUL")
        }
        let request = FileOpcode.metadataSet.bytes + bigEndian(fid) + Array(json.utf8) + [0]
        guard request.count <= maxPayload else {
            throw KRError.invalidArgument(reason: "metadata payload has \(request.count) bytes, limit \(maxPayload)")
        }
        return request
    }
}
