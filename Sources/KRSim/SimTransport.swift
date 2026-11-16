//
//  SimTransport.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRCore
import KRTransport
import KRWire

/// A `Transport` backed by a `SimDevice`, with reply latency, cable and power events, and debug loops.
public actor SimTransport: Transport {
    private struct PendingReply {
        var due: ContinuousClock.Instant
        var frames: [[UInt8]]
    }
    
    private let replyDelay: Duration
    private let debugPeriod: Duration
    private var continuation: AsyncStream<[UInt8]>.Continuation?
    private var outbox: [PendingReply] = []
    private var drainTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var sentWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    
    public private(set) var device: SimDevice
    public private(set) var sentFrames: [[UInt8]] = []
    
    public init(
        device: SimDevice = .init(),
        replyDelay: Duration = .zero,
        debugPeriod: Duration = .milliseconds(1030)
    ) {
        self.device = device
        self.replyDelay = replyDelay
        self.debugPeriod = debugPeriod
    }
    
    public func connect() async throws(KRError) -> AsyncStream<[UInt8]> {
        guard continuation == nil else {
            throw KRError.alreadyConnected
        }
        let (stream, newContinuation) = AsyncStream<[UInt8]>.makeStream()
        continuation = newContinuation
        startLoopIfNeeded()
        return stream
    }
    
    public func send(_ frame: [UInt8]) async throws(KRError) {
        guard continuation != nil else {
            throw KRError.disconnected
        }
        sentFrames.append(frame)
        let ready = sentWaiters.filter { $0.count <= sentFrames.count }
        sentWaiters.removeAll { $0.count <= sentFrames.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        // A request that arrives while an earlier reply is still queued overlaps it.
        if !outbox.isEmpty {
            if !device.isLooping {
                device.enterDebugLoop(text: SimDevice.overlapText)
            }
        } else {
            schedule(device.receive(frame))
        }
        startLoopIfNeeded()
    }
    
    public func disconnect() async {
        closeStream()
    }
    
    public func unplug() {
        closeStream()
    }
    
    public func powerCycle() {
        device.powerCycle()
        closeStream()
    }
    
    public func inject(_ fault: SimFault) {
        device.inject(fault)
    }
    
    /// The first debug frame comes one `debugPeriod` after the call.
    public func enterDebugLoop(text: String) {
        device.enterDebugLoop(text: text)
        loopTask?.cancel()
        loopTask = nil
        startLoopIfNeeded()
    }
    
    /// Also returns when the stream closes (disconnect, unplug, power cycle), so callers never hang.
    public func waitForSent(count: Int) async {
        guard sentFrames.count < count else { return }
        await withCheckedContinuation { continuation in
            sentWaiters.append((count: count, continuation: continuation))
        }
    }
    
    private func schedule(_ replies: [[UInt8]]) {
        guard !replies.isEmpty else { return }
        if replyDelay <= .zero {
            for reply in replies {
                continuation?.yield(reply)
            }
            return
        }
        outbox.append(PendingReply(due: .now + replyDelay, frames: replies))
        if drainTask == nil {
            drainTask = Task { await drain() }
        }
    }
    
    private func drain() async {
        while let next = outbox.first {
            do {
                try await Task.sleep(until: next.due, clock: ContinuousClock())
            } catch {
                return
            }
            guard !Task.isCancelled, !outbox.isEmpty else { return }
            outbox.removeFirst()
            for frame in next.frames {
                continuation?.yield(frame)
            }
        }
        drainTask = nil
    }
    
    private func startLoopIfNeeded() {
        guard device.isLooping, continuation != nil, loopTask == nil else { return }
        loopTask = Task { await runLoop() }
    }
    
    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: debugPeriod)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard device.isLooping, let text = device.debugText else { return }
            continuation?.yield(SysExFrame.debugFrame(product: device.product, text: text))
        }
    }
    
    private func closeStream() {
        loopTask?.cancel()
        loopTask = nil
        drainTask?.cancel()
        drainTask = nil
        outbox.removeAll()
        continuation?.finish()
        continuation = nil
        let waiters = sentWaiters
        sentWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}
