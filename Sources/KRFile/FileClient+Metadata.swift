//
//  FileClient+Metadata.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRCore

extension FileClient {
    /// Raw JSON text of the node, or of one key. Parsing belongs to the caller.
    public func metadata(fid: UInt16, key: String? = nil) async throws(KRError) -> String {
        _ = try FileCodec.metadataGetRequest(fid: fid, page: 0, key: key)
        return try await withGate { () async throws(KRError) -> String in
            try await self.reinitIfIdle()
            var text = ""
            var page: UInt16 = 0
            while true {
                if Task.isCancelled {
                    throw KRError.cancelled
                }
                let payload = try await self.performRequest(
                    FileCodec.metadataGetRequest(fid: fid, page: page, key: key),
                    timeout: nil
                )
                guard let chunk = try FileCodec.metadataPage(payload, expectedPage: page) else {
                    return text
                }
                text += chunk.text
                if chunk.isLast {
                    return text
                }
                guard page < UInt16.max else {
                    throw KRError.malformedResponse(reason: "metadata exceeds \(UInt16.max) pages")
                }
                page += 1
            }
        }
    }
    
    /// `json` is sent verbatim; typing rules belong to the caller.
    @_spi(UnsafeDeviceLab) public func setMetadata(fid: UInt16, json: String) async throws(KRError) {
        _ = try FileCodec.metadataSetRequest(fid: fid, json: json, maxPayload: FileCodec.putPayloadBytes(chunkSize: chunkSize))
        try await withGate { () async throws(KRError) -> Void in
            try await self.prepareMutation()
            try await self.reinitIfIdle()
            let request = try FileCodec.metadataSetRequest(
                fid: fid,
                json: json,
                maxPayload: FileCodec.putPayloadBytes(chunkSize: self.chunkSize)
            )
            _ = try await self.performRequest(request, timeout: nil)
        }
    }
}
