//
//  SafeWriter+Preflight.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
import KRCore
import KRFile

extension WriteRequest {
    /// Metadata sent right after the data of a put or replace; `nil` for the other operations.
    var postPutMetadata: MetadataJSON? {
        switch self {
        case .put(_, _, let metadata), .replace(_, _, let metadata):
            return MetadataJSON(entries: [
                "samplerate": .number(Double(metadata.samplerate)),
                "channels": .number(Double(metadata.channels)),
                "format": .string("s16"),
                "name": .string(metadata.name)
            ])
        case .delete, .setMetadata, .restore:
            return nil
        }
    }
}

extension SafeWriter {
    private static let soundsNode: UInt16 = 1000
    private static let slots: ClosedRange<UInt16> = 1...999
    
    /// Reads the slot and refuses before anything is written.
    func preflight(_ request: WriteRequest) async throws(SafeWriteError) -> SlotSnapshot {
        try await validateInput(request)
        try await checkClientAndStore(request)
        do throws(KRError) {
            try await client.preflightMutation()
        } catch {
            throw Self.refusal(forPreflight: error)
        }
        let snapshot = try await readSlot(request.fid)
        try match(request, snapshot)
        return snapshot
    }
    
    private func validateInput(_ request: WriteRequest) async throws(SafeWriteError) {
        guard Self.slots.contains(request.fid) else {
            throw .refused(.notSampleSlot, underlying: nil)
        }
        switch request {
        case .put(_, let data, let metadata), .replace(_, let data, let metadata):
            guard isValidName(metadata.name) else {
                throw .refused(.invalidName, underlying: nil)
            }
            try await validate(data: data, channels: metadata.channels)
            let limit = await client.maxMetadataJSONBytes
            if let json = request.postPutMetadata, json.serialized.utf8.count > limit {
                throw .refused(.invalidMetadata, underlying: nil)
            }
        case .setMetadata(_, let text):
            try await validate(metadataText: text)
        case .delete, .restore:
            break
        }
    }
    
    private func validate(data: [UInt8], channels: UInt8) async throws(SafeWriteError) {
        guard channels == 1 || channels == 2, !data.isEmpty else {
            throw .refused(.invalidData, underlying: nil)
        }
        let frameBytes = 2 * Int(channels)
        let limit = await client.maxWriteDataBytes
        guard data.count % frameBytes == 0, data.count <= limit, UInt32(exactly: data.count) != nil else {
            throw .refused(.invalidData, underlying: nil)
        }
    }
    
    private func validate(metadataText text: String) async throws(SafeWriteError) {
        let limit = await client.maxMetadataJSONBytes
        guard text.utf8.count <= limit, let json = MetadataJSON(parsing: text), !json.entries.isEmpty else {
            throw .refused(.invalidMetadata, underlying: nil)
        }
        guard json.entries.keys.allSatisfy({ !MetadataJSON.readOnlyKeys.contains($0) }) else {
            throw .refused(.readOnlyKey, underlying: nil)
        }
        if let name = json.entries["name"] {
            guard case .string(let value) = name, isValidName(value) else {
                throw .refused(.invalidName, underlying: nil)
            }
        }
    }
    
    private func isValidName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        return (1...configuration.maxNameLength).contains(scalars.count)
            && scalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }
    
    private func checkClientAndStore(_ request: WriteRequest) async throws(SafeWriteError) {
        guard await client.isConnected else {
            throw .refused(.notConnected, underlying: nil)
        }
        if await client.isHalted {
            throw .refused(.halted, underlying: nil)
        }
        if case .restore = request {
            try await refuseIfInterrupted()
            return
        }
        if pendingInMemory != nil {
            throw .refused(.pendingRecovery, underlying: nil)
        }
        let record: PendingRecovery?
        do {
            record = try await store.pendingRecovery()
        } catch {
            throw .refused(.checkpointFailed, underlying: nil)
        }
        if let record {
            pendingInMemory = record
            throw .refused(.pendingRecovery, underlying: nil)
        }
        try await refuseIfInterrupted()
    }
    
    private func refuseIfInterrupted() async throws(SafeWriteError) {
        if await client.transferInterrupted {
            throw .refused(.transferInterrupted, underlying: nil)
        }
    }
    
    private func readSlot(_ fid: UInt16) async throws(SafeWriteError) -> SlotSnapshot {
        let generation = await client.connectionGeneration
        let stat: FileStat?
        let json: String?
        do throws(KRError) {
            let nodes = try await client.list(node: Self.soundsNode)
            if nodes.contains(where: { $0.id == fid }) {
                stat = try await client.stat(fid: fid)
                json = try await client.metadata(fid: fid)
            } else {
                stat = nil
                json = nil
            }
        } catch {
            throw Self.refusal(forRead: error)
        }
        if let stat, stat.parent != Self.soundsNode {
            throw .refused(.notSampleSlot, underlying: nil)
        }
        if await connectionChanged(since: generation) {
            throw .refused(.notConnected, underlying: nil)
        }
        return SlotSnapshot(fid: fid, present: stat != nil, stat: stat, metadataJSON: json, generation: generation)
    }
    
    private func match(_ request: WriteRequest, _ snapshot: SlotSnapshot) throws(SafeWriteError) {
        switch request {
        case .put where snapshot.present:
            throw .refused(.slotOccupied, underlying: nil)
        case .replace where !snapshot.present, .delete where !snapshot.present, .setMetadata where !snapshot.present:
            throw .refused(.slotEmpty, underlying: nil)
        default:
            break
        }
    }
    
    private static func refusal(forPreflight error: KRError) -> SafeWriteError {
        switch error {
        case .deviceDebugFrame:
            return .refused(.debugLoop, underlying: error)
        case .transferInterrupted:
            return .refused(.transferInterrupted, underlying: error)
        case .disconnected:
            return .refused(.notConnected, underlying: error)
        default:
            return .refused(.preflightFailed, underlying: error)
        }
    }
    
    private static func refusal(forRead error: KRError) -> SafeWriteError {
        switch error {
        case .deviceDebugFrame:
            return .refused(.debugLoop, underlying: error)
        default:
            return .refused(.preflightFailed, underlying: error)
        }
    }
}
