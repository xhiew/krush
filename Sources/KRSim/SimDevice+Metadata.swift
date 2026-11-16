//
//  SimDevice+Metadata.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRWire

extension SimDevice {
    private static let getHeaderBytes = 6
    
    mutating func handleMetadataSet(_ request: FileRequest) -> [[UInt8]] {
        let payload = request.payload
        guard let fid = SimBytes.u16(payload, at: 2) else { return reject(request, "invalid request") }
        guard var node = fileSystem.node(fid) else { return reject(request, "invalid id") }
        // Sim-chosen reason.
        guard let values = SimJSONObject.parse(SimBytes.cString(payload, at: 4)) else {
            return reject(request, "invalid json")
        }
        node.metadata.merge(values) { _, new in new }
        fileSystem.insert(node)
        return respond(request)
    }
    
    func handleMetadataGet(_ request: FileRequest) -> [[UInt8]] {
        let payload = request.payload
        guard let fid = SimBytes.u16(payload, at: 2), let page = SimBytes.u16(payload, at: 4) else {
            return reject(request, "invalid request")
        }
        guard let node = fileSystem.node(fid) else { return reject(request, "invalid id") }
        var values = node.metadata
        if payload.count > Self.getHeaderBytes {
            let key = SimBytes.cString(payload, at: Self.getHeaderBytes)
            values = node.metadata[key].map { [key: $0] } ?? [:]
        }
        let text = Array(SimJSONObject.serialize(values).utf8)
        let pageCount = max(1, (text.count + metadataPageBytes - 1) / metadataPageBytes)
        guard Int(page) < pageCount else { return respond(request, SimBytes.be16(page)) }
        let start = Int(page) * metadataPageBytes
        let chunk = text[start..<min(start + metadataPageBytes, text.count)]
        let terminator: [UInt8] = Int(page) == pageCount - 1 ? [0] : []
        return respond(request, SimBytes.be16(page) + chunk + terminator)
    }
}
