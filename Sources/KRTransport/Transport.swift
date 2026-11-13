//
//  Transport.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore

/// A byte pipe to one device that speaks whole SysEx frames.
///
/// Contract:
/// - Every element of the stream is exactly one complete `F0…F7` frame with
///   realtime bytes already filtered out.
/// - The stream finishes on `disconnect()` or when the device is unplugged.
/// - Each `connect()` returns a new stream with a single consumer.
/// - Calling `connect()` while connected throws `.alreadyConnected`.
public protocol Transport: Sendable {
    func connect() async throws(KRError) -> AsyncStream<[UInt8]>
    
    func send(_ frame: [UInt8]) async throws(KRError)
    
    func disconnect() async
}
