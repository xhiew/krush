//
//  FakeTransport.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore
import KRTransport
import KRWire

actor FakeTransport: Transport {
    typealias Responder = @Sendable ([UInt8]) -> [[UInt8]]
    
    private var initialFrames: [[UInt8]]
    private var responder: Responder?
    private let replyDelay: Duration
    private let deferFinishOnDisconnect: Bool
    private let autoReplyInit: Bool
    
    private var continuation: AsyncStream<[UInt8]>.Continuation?
    private var deferredContinuations: [AsyncStream<[UInt8]>.Continuation] = []
    private var sentWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var holdPredicate: (@Sendable ([UInt8]) -> Bool)?
    private var heldSend: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    /// With `autoReplyInit`, INIT requests are answered here and kept out of `sentFrames`.
    private(set) var sentFrames: [[UInt8]] = []
    private(set) var initFrames: [[UInt8]] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var maxInFlight = 0
    private var inFlight = 0
    
    init(
        initialFrames: [[UInt8]] = [],
        responder: Responder? = nil,
        replyDelay: Duration = .zero,
        deferFinishOnDisconnect: Bool = false,
        autoReplyInit: Bool = false
    ) {
        self.initialFrames = initialFrames
        self.responder = responder
        self.replyDelay = replyDelay
        self.deferFinishOnDisconnect = deferFinishOnDisconnect
        self.autoReplyInit = autoReplyInit
    }
    
    static let initReplyPayload: [UInt8] = [0x00, 0x00, 0x00, 0x02, 0x00]
    
    private static func isInit(_ frame: [UInt8]) -> Bool {
        guard case .request(let request)? = try? SysExFrame.parse(frame) else { return false }
        return request.payload.first == 0x01
    }
    
    func setResponder(_ responder: Responder?) {
        self.responder = responder
    }
    
    func setInitialFrames(_ frames: [[UInt8]]) {
        initialFrames = frames
    }
    
    func connect() async throws(KRError) -> AsyncStream<[UInt8]> {
        guard continuation == nil else {
            throw KRError.alreadyConnected
        }
        connectCount += 1
        let (stream, newContinuation) = AsyncStream<[UInt8]>.makeStream()
        continuation = newContinuation
        for frame in initialFrames {
            newContinuation.yield(frame)
        }
        return stream
    }
    
    func send(_ frame: [UInt8]) async throws(KRError) {
        guard let target = continuation else {
            throw KRError.disconnected
        }
        if let predicate = holdPredicate, predicate(frame) {
            holdPredicate = nil
            await withCheckedContinuation { continuation in
                heldSend = continuation
                let waiters = heldWaiters
                heldWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        if autoReplyInit, Self.isInit(frame) {
            initFrames.append(frame)
            target.yield(TestFrames.response(id: TestFrames.requestID(of: frame), raw: Self.initReplyPayload))
            return
        }
        sentFrames.append(frame)
        let ready = sentWaiters.filter { $0.count <= sentFrames.count }
        sentWaiters.removeAll { $0.count <= sentFrames.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        guard let responder else { return }
        let replies = responder(frame)
        if replyDelay > .zero {
            let delay = replyDelay
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            Task {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    closeInFlight()
                    return
                }
                for reply in replies {
                    target.yield(reply)
                }
                closeInFlight()
            }
        } else {
            for reply in replies {
                target.yield(reply)
            }
        }
    }
    
    func disconnect() async {
        disconnectCount += 1
        guard let current = continuation else { return }
        continuation = nil
        if deferFinishOnDisconnect {
            deferredContinuations.append(current)
        } else {
            current.finish()
        }
    }
    
    private func closeInFlight() {
        inFlight -= 1
    }
    
    func emitOnPreviousStreams(_ frame: [UInt8]) {
        for deferred in deferredContinuations {
            deferred.yield(frame)
        }
    }
    
    func reply(_ frames: [[UInt8]]) {
        for frame in frames {
            continuation?.yield(frame)
        }
    }
    
    func emit(_ frame: [UInt8]) {
        continuation?.yield(frame)
    }
    
    func finish() {
        continuation?.finish()
        continuation = nil
    }
    
    func finishPreviousStream() {
        for deferred in deferredContinuations {
            deferred.finish()
        }
        deferredContinuations.removeAll()
    }
    
    /// Suspends the next `send` whose frame matches, until `releaseHeldSend()`.
    func holdSend(where predicate: @escaping @Sendable ([UInt8]) -> Bool) {
        holdPredicate = predicate
    }

    func waitForHeldSend() async {
        guard heldSend == nil else { return }
        await withCheckedContinuation { continuation in
            heldWaiters.append(continuation)
        }
    }

    func releaseHeldSend() {
        heldSend?.resume()
        heldSend = nil
    }

    func waitForSent(count: Int) async {
        guard sentFrames.count < count else { return }
        await withCheckedContinuation { continuation in
            sentWaiters.append((count: count, continuation: continuation))
        }
    }
}
