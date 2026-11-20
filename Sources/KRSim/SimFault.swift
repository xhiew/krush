//
//  SimFault.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

/// Opcodes are matched as a prefix of the request payload, e.g. `[0x03, 0x01]` for GET data.
/// Overlapping requests, GET past EOF and PUT after an abandoned GET always trigger a debug loop.
public enum SimFault: Sendable, Equatable {
    case silence(opcode: [UInt8])
    case reject(opcode: [UInt8], reason: String)
    case debugLoop(onOpcode: [UInt8], text: String)
    /// Answers status 0 without changing anything.
    case ackWithoutEffect(opcode: [UInt8])
    /// Flips the bits of byte 0 when a PUT commits.
    case corruptCommit
}
