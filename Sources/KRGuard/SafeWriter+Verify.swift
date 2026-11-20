//
//  SafeWriter+Verify.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import KRCore
import KRFile

extension SafeWriter {
    enum VerifyResult {
        case match
        case mismatch
        case readFailed(KRError)
    }
    
    func verifySample(fid: UInt16, data: [UInt8], name: String, verifyBytes: Bool) async -> VerifyResult {
        do throws(KRError) {
            let nodes = try await client.list(node: FileNode.soundsID)
            guard nodes.contains(where: { $0.id == fid }) else { return .mismatch }
            if verifyBytes {
                guard try await client.read(fid: fid).data == data else { return .mismatch }
            } else {
                guard try await client.stat(fid: fid).size == UInt32(truncatingIfNeeded: data.count) else { return .mismatch }
            }
            let text = try await client.metadata(fid: fid)
            guard let json = MetadataJSON(parsing: text), json.entries["name"] == .string(name) else { return .mismatch }
            return .match
        } catch {
            return .readFailed(error)
        }
    }
    
    /// Every expected key must read back with the same value.
    func verifyKeys(fid: UInt16, expected: MetadataJSON) async -> VerifyResult {
        do throws(KRError) {
            let text = try await client.metadata(fid: fid)
            guard let current = MetadataJSON(parsing: text) else { return .mismatch }
            for (key, value) in expected.entries where current.entries[key] != value {
                return .mismatch
            }
            return .match
        } catch {
            return .readFailed(error)
        }
    }
    
    /// `nil` when the read failed or the text is not flat JSON.
    func readMetadataEntries(fid: UInt16) async -> MetadataJSON? {
        guard let text = try? await client.metadata(fid: fid) else { return nil }
        return MetadataJSON(parsing: text)
    }
    
    /// LIST only: metadata of a deleted slot may still read back as a ghost.
    func verifyAbsent(fid: UInt16) async -> VerifyResult {
        do throws(KRError) {
            let nodes = try await client.list(node: FileNode.soundsID)
            return nodes.contains(where: { $0.id == fid }) ? .mismatch : .match
        } catch {
            return .readFailed(error)
        }
    }
    
    /// Whether the slot equals what the checkpoint recorded; `nil` when it could not be read.
    func matches(checkpoint: Checkpoint) async -> Bool? {
        do throws(KRError) {
            let nodes = try await client.list(node: FileNode.soundsID)
            let present = nodes.contains(where: { $0.id == checkpoint.fid })
            guard let prior = checkpoint.prior else { return !present }
            guard present else { return false }
            let stat = try await client.stat(fid: checkpoint.fid)
            guard stat.size == prior.size, stat.name == prior.nodeName else { return false }
            if let data = prior.data {
                return try await client.read(fid: checkpoint.fid).data == [UInt8](data)
            }
            return true
        } catch {
            return nil
        }
    }
}
