//
//  SafeWriter.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation
import KRCore
@_spi(UnsafeDeviceLab) import KRFile

enum WriteRequest: Sendable {
    case put(slot: UInt16, data: [UInt8], metadata: SampleMetadata)
    case replace(slot: UInt16, data: [UInt8], metadata: SampleMetadata)
    case delete(slot: UInt16)
    case setMetadata(slot: UInt16, json: String)
    case restore(slot: UInt16)
    
    var fid: UInt16 {
        switch self {
        case .put(let slot, _, _), .replace(let slot, _, _), .delete(let slot),
             .setMetadata(let slot, _), .restore(let slot):
            return slot
        }
    }
    
    var operation: Checkpoint.Operation {
        switch self {
        case .put: return .put
        case .replace: return .replace
        case .delete: return .delete
        case .setMetadata: return .setMetadata
        case .restore: return .restore
        }
    }
}

/// The only supported way to change a sample slot. One operation runs at a time, in arrival order.
public actor SafeWriter {
    let client: FileClient
    let store: any CheckpointStore
    let configuration: SafeWriterConfiguration
    var pendingInMemory: PendingRecovery?
    
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    public init(
        client: FileClient,
        store: any CheckpointStore,
        configuration: SafeWriterConfiguration = .init()
    ) {
        self.client = client
        self.store = store
        self.configuration = configuration
    }
    
    /// Takes the FIFO gate, runs `body` in its own task so the caller's cancellation never reaches the device commands,
    /// and rethrows the typed error. The gate ignores cancellation: a cancelled caller still waits for its turn.
    func run<T: Sendable>(
        _ body: @escaping @Sendable () async -> Result<T, SafeWriteError>
    ) async throws(SafeWriteError) -> T {
        await acquire()
        let task = Task { await body() }
        let result = await task.value
        release()
        return try result.get()
    }
    
    /// Always remembers the record in memory, so writes stay blocked even when the store cannot save it.
    func recordPending(
        step: WriteStep,
        checkpoint: Checkpoint,
        reason: String
    ) async -> (record: PendingRecovery, saved: Bool) {
        let record = PendingRecovery(
            checkpointID: checkpoint.id,
            fid: checkpoint.fid,
            operation: checkpoint.operation,
            step: step,
            reason: reason
        )
        pendingInMemory = record
        do {
            try await store.savePendingRecovery(record)
            return (record, true)
        } catch {
            return (record, false)
        }
    }
    
    /// A changed generation means the connection was re-established since `generation` was read.
    func connectionChanged(since generation: UInt64) async -> Bool {
        await client.connectionGeneration != generation
    }
    
    private func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
    
    private func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
