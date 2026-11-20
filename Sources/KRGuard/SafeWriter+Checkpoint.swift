//
//  SafeWriter+Checkpoint.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
import KRCore
import KRFile

extension SafeWriter {
    /// Saves what is needed to undo `request`. Throws before any write frame is sent.
    func checkpoint(
        _ request: WriteRequest,
        snapshot: SlotSnapshot,
        captureData: Bool
    ) async throws(SafeWriteError) -> Checkpoint {
        let checkpoint = try await makeCheckpoint(request, snapshot: snapshot, captureData: captureData)
        do {
            try await store.save(checkpoint)
        } catch {
            throw .refused(.checkpointFailed, underlying: nil)
        }
        if await connectionChanged(since: snapshot.generation) {
            throw .refused(.notConnected, underlying: nil)
        }
        return checkpoint
    }
    
    private func makeCheckpoint(
        _ request: WriteRequest,
        snapshot: SlotSnapshot,
        captureData: Bool
    ) async throws(SafeWriteError) -> Checkpoint {
        let fid = request.fid
        switch request {
        case .put(_, let data, _):
            return Checkpoint(fid: fid, operation: .put, prior: nil, expectedSize: UInt32(truncatingIfNeeded: data.count))
        case .replace(_, let data, _):
            return Checkpoint(
                fid: fid,
                operation: .replace,
                prior: try await prior(of: snapshot, captureData: captureData),
                expectedSize: UInt32(truncatingIfNeeded: data.count),
                restoreMetadataParts: try await restoreParts(of: snapshot)
            )
        case .delete:
            return Checkpoint(
                fid: fid,
                operation: .delete,
                prior: try await prior(of: snapshot, captureData: captureData),
                restoreMetadataParts: try await restoreParts(of: snapshot)
            )
        case .setMetadata(_, let text):
            return try await metadataCheckpoint(fid: fid, text: text, snapshot: snapshot)
        case .restore:
            return Checkpoint(fid: fid, operation: .restore, prior: try await prior(of: snapshot, captureData: false))
        }
    }
    
    private func prior(of snapshot: SlotSnapshot, captureData: Bool) async throws(SafeWriteError) -> Checkpoint.PriorSlot? {
        guard let stat = snapshot.stat, let json = snapshot.metadataJSON else { return nil }
        var data: Data?
        if captureData {
            do throws(KRError) {
                data = Data(try await client.read(fid: snapshot.fid).data)
            } catch {
                throw .refused(.checkpointFailed, underlying: error)
            }
        }
        return Checkpoint.PriorSlot(nodeName: stat.name, flags: stat.flags, size: stat.size, data: data, metadataJSON: json)
    }
    
    /// Old metadata for a fresh PUT: no `crc`, split so each part fits one metadata set.
    private func restoreParts(of snapshot: SlotSnapshot) async throws(SafeWriteError) -> [String] {
        let limit = await client.maxMetadataJSONBytes
        guard let text = snapshot.metadataJSON,
              let json = MetadataJSON(parsing: text),
              let parts = json.removing(keys: ["crc"]).split(maxBytes: limit) else {
            throw .refused(.checkpointFailed, underlying: nil)
        }
        return parts
    }
    
    private func metadataCheckpoint(
        fid: UInt16,
        text: String,
        snapshot: SlotSnapshot
    ) async throws(SafeWriteError) -> Checkpoint {
        let limit = await client.maxMetadataJSONBytes
        guard let new = MetadataJSON(parsing: text),
              let oldText = snapshot.metadataJSON,
              let old = MetadataJSON(parsing: oldText),
              let stat = snapshot.stat else {
            throw .refused(.checkpointFailed, underlying: nil)
        }
        let keys = new.keys
        guard old.restricting(to: keys).serialized.utf8.count <= limit else {
            throw .refused(.checkpointFailed, underlying: nil)
        }
        let prior = Checkpoint.PriorSlot(nodeName: stat.name, flags: stat.flags, size: stat.size, data: nil, metadataJSON: oldText)
        return Checkpoint(fid: fid, operation: .setMetadata, prior: prior, writtenKeys: keys)
    }
}
