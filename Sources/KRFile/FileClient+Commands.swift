//
//  FileClient+Commands.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore

extension FileClient {
    public func list(node: UInt16) async throws(KRError) -> [FileNode] {
        try await withGate { () async throws(KRError) -> [FileNode] in
            try await self.reinitIfIdle()
            var nodes: [FileNode] = []
            var page: UInt16 = 0
            while true {
                if Task.isCancelled {
                    throw KRError.cancelled
                }
                let payload = try await self.performRequest(
                    FileCodec.listRequest(page: page, node: node),
                    timeout: nil
                )
                guard let entries = try FileCodec.listPage(payload, expectedPage: page) else {
                    return nodes
                }
                nodes += entries
                guard page < UInt16.max else {
                    throw KRError.malformedResponse(reason: "list exceeds \(UInt16.max) pages")
                }
                page += 1
            }
        }
    }
    
    public func stat(fid: UInt16) async throws(KRError) -> FileStat {
        try await withGate { () async throws(KRError) -> FileStat in
            try await self.reinitIfIdle()
            let payload = try await self.performRequest(FileCodec.statRequest(fid: fid), timeout: nil)
            return try FileCodec.stat(payload)
        }
    }
    
    public func play(fid: UInt16) async throws(KRError) {
        try await withGate { () async throws(KRError) -> Void in
            try self.ensureNotInterrupted()
            try await self.reinitIfIdle()
            _ = try await self.performRequest(FileCodec.playRequest(fid: fid), timeout: nil)
        }
    }
    
    @_spi(UnsafeDeviceLab) public func delete(fid: UInt16) async throws(KRError) {
        try await withGate { () async throws(KRError) -> Void in
            try await self.prepareMutation()
            try await self.reinitIfIdle()
            _ = try await self.performRequest(
                FileCodec.deleteRequest(fid: fid),
                timeout: self.configuration.deleteTimeout
            )
        }
    }
}
