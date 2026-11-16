//
//  FileClient.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore
import KRTransport
import KRWire

/// Runs one sequential FILE session. Callers are queued FIFO and never overlap
/// on the device; a debug frame halts the client until a clean reconnect.
public actor FileClient {
    private enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }
    
    private struct FrameWaiter {
        let token: UInt64
        let continuation: CheckedContinuation<Result<ParsedFrame, KRError>?, Never>
        let timer: Task<Void, Never>
    }
    
    private struct GateWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Result<Void, KRError>, Never>
    }
    
    private static let mailboxLimit = 64
    
    private let transport: any Transport
    private let product: Product
    let configuration: FileClientConfiguration
    private var ids = RequestIDGenerator()
    
    public private(set) var chunkSize = FileCodec.defaultChunkSize
    
    private var state: ConnectionState = .disconnected
    private var sessionID: UInt64 = 0
    private var pump: Task<Void, Never>?
    private var halted: String?
    private var debugCount = 0
    private(set) var lastSuccess = ContinuousClock.now
    private var listeningSince = ContinuousClock.now
    
    private(set) var mailbox: [ParsedFrame] = []
    private var frameWaiter: FrameWaiter?
    private var nextToken: UInt64 = 0
    
    private var isBusy = false
    private var holderSession: UInt64 = 0
    private var gateQueue: [GateWaiter] = []
    private var nextGateID: UInt64 = 0
    
    public private(set) var transferInterrupted: Bool
    private let onInterruptedTransferChange: (@Sendable (Bool) -> Void)?
    
    public init(
        transport: any Transport,
        product: Product,
        configuration: FileClientConfiguration = .init(),
        interruptedTransfer: Bool = false,
        onInterruptedTransferChange: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.transport = transport
        self.product = product
        self.configuration = configuration
        self.transferInterrupted = interruptedTransfer
        self.onInterruptedTransferChange = onInterruptedTransferChange
    }
    
    var currentSession: UInt64 {
        sessionID
    }
    
    var isHalted: Bool {
        halted != nil
    }
    
    public func connect() async throws(KRError) {
        guard state == .disconnected else {
            throw KRError.alreadyConnected
        }
        state = .connecting
        sessionID &+= 1
        let session = sessionID
        mailbox.removeAll()
        let stream: AsyncStream<[UInt8]>
        do throws(KRError) {
            stream = try await transport.connect()
        } catch {
            if session == sessionID {
                state = .disconnected
            }
            throw error
        }
        guard session == sessionID else {
            if state == .disconnected {
                await transport.disconnect()
            }
            throw KRError.disconnected
        }
        pump = startPump(stream: stream, session: session)
        listeningSince = .now
        do throws(KRError) {
            try await settleSession()
            guard session == sessionID else {
                throw KRError.disconnected
            }
            // Connected only once INIT holds the gate, so no request can run before INIT.
            try await withGate { () async throws(KRError) -> Void in
                guard session == self.sessionID else {
                    throw KRError.disconnected
                }
                self.state = .connected
                try await self.initialize()
            }
        } catch {
            await abortConnect(session: session)
            throw error
        }
        guard session == sessionID else {
            throw KRError.disconnected
        }
    }
    
    public func disconnect() async {
        sessionID &+= 1
        state = .disconnected
        pump?.cancel()
        pump = nil
        mailbox.removeAll()
        resumeFrameWaiter(with: .failure(.disconnected))
        let queued = gateQueue
        gateQueue.removeAll()
        for waiter in queued {
            waiter.continuation.resume(returning: .failure(.disconnected))
        }
        await transport.disconnect()
    }
    
    func request(_ raw: [UInt8], timeout: Duration? = nil) async throws(KRError) -> [UInt8] {
        try await withGate { () async throws(KRError) -> [UInt8] in
            try await self.performRequest(raw, timeout: timeout)
        }
    }
    
    func performRequest(_ raw: [UInt8], timeout: Duration?) async throws(KRError) -> [UInt8] {
        var didSend = false
        return try await performRequest(raw, timeout: timeout, didSend: &didSend)
    }
    
    /// `didSend` turns true once the frame left the transport, before waiting for the reply.
    func performRequest(
        _ raw: [UInt8],
        timeout: Duration?,
        honorsCancellation: Bool = true,
        didSend: inout Bool
    ) async throws(KRError) -> [UInt8] {
        if let text = halted {
            throw KRError.deviceDebugFrame(text: text)
        }
        guard state == .connected, holderSession == sessionID else {
            throw KRError.disconnected
        }
        if honorsCancellation, Task.isCancelled {
            throw KRError.cancelled
        }
        let session = sessionID
        let id = ids.next()
        try await transport.send(SysExFrame.fileRequest(product: product, id: id, payload: raw))
        didSend = true
        guard session == sessionID else {
            throw KRError.disconnected
        }
        let deadline = ContinuousClock.now + (timeout ?? configuration.requestTimeout)
        while let result = await nextFrame(until: deadline) {
            guard session == sessionID else {
                throw KRError.disconnected
            }
            switch result {
            case .failure(let error):
                throw error
            case .success(.debug(let frame)):
                throw frame.error
            case .success(.response(let response)) where response.matches(id, command: .file):
                try response.check()
                lastSuccess = .now
                return response.payload
            case .success:
                continue
            }
        }
        // A sent request keeps the gate until here even if its Task was cancelled.
        if honorsCancellation, Task.isCancelled {
            throw KRError.cancelled
        }
        guard session == sessionID else {
            throw KRError.disconnected
        }
        try await listen(for: configuration.debugGrace, session: session)
        throw KRError.timeout(requestID: id.value)
    }
    
    /// Gate holder only.
    func initialize(honorsCancellation: Bool = true) async throws(KRError) {
        var didSend = false
        let payload = try await performRequest(
            FileCodec.initRequest(flags: configuration.initFlags, maxResponseLength: configuration.maxResponseLength),
            timeout: nil,
            honorsCancellation: honorsCancellation,
            didSend: &didSend
        )
        chunkSize = FileCodec.chunkSize(initResponse: payload)
    }
    
    /// Gate holder only.
    func reinitIfIdle() async throws(KRError) {
        guard ContinuousClock.now - lastSuccess > configuration.idleReinit else { return }
        try await initialize()
    }
    
    /// Gate holder only. Call before any frame of a write command is sent.
    func prepareMutation() async throws(KRError) {
        if let text = halted {
            throw KRError.deviceDebugFrame(text: text)
        }
        try ensureNotInterrupted()
        let remaining = configuration.mutationPreflight - (ContinuousClock.now - listeningSince)
        if remaining > .zero {
            try await listen(for: remaining, session: sessionID)
        }
    }
    
    // MARK: - Interrupted transfer lock
    
    /// Same checks `performRequest` makes before sending; call before taking the lock so a request that cannot leave never locks.
    func ensureCanStartTransfer() throws(KRError) {
        if let text = halted {
            throw KRError.deviceDebugFrame(text: text)
        }
        guard state == .connected, holderSession == sessionID else {
            throw KRError.disconnected
        }
        if Task.isCancelled {
            throw KRError.cancelled
        }
    }
    
    func markTransferInterrupted() {
        setTransferInterrupted(true)
    }
    
    /// A transfer that ended cleanly, or never reached the device.
    func releaseTransferLock() {
        setTransferInterrupted(false)
    }
    
    func ensureNotInterrupted() throws(KRError) {
        if transferInterrupted {
            throw KRError.transferInterrupted
        }
    }
    
    /// Call only after the user power-cycled the device.
    public func clearInterruptedTransfer() throws(KRError) {
        guard state == .disconnected else {
            throw KRError.invalidArgument(reason: "disconnect first")
        }
        setTransferInterrupted(false)
    }
    
    private func setTransferInterrupted(_ value: Bool) {
        guard transferInterrupted != value else { return }
        transferInterrupted = value
        onInterruptedTransferChange?(value)
    }
    
    func pause(_ duration: Duration) async throws(KRError) {
        do {
            try await Task.sleep(for: duration)
        } catch {
            throw KRError.cancelled
        }
    }
    
    private func settleSession() async throws(KRError) {
        let wasHalted = halted != nil
        let startCount = debugCount
        try await listen(for: wasHalted ? configuration.haltedPreflight : configuration.drainWindow, session: sessionID)
        if debugCount != startCount {
            throw KRError.deviceDebugFrame(text: halted ?? "")
        }
        halted = nil
    }
    
    /// Discards everything except debug frames, which end the wait with an error.
    func listen(for duration: Duration, session: UInt64) async throws(KRError) {
        guard session == sessionID else {
            throw KRError.disconnected
        }
        let deadline = ContinuousClock.now + duration
        while let result = await nextFrame(until: deadline) {
            guard session == sessionID else {
                throw KRError.disconnected
            }
            switch result {
            case .failure(let error):
                throw error
            case .success(.debug(let frame)):
                throw frame.error
            case .success:
                continue
            }
        }
    }
    
    private func abortConnect(session: UInt64) async {
        guard session == sessionID else { return }
        sessionID &+= 1
        state = .disconnected
        pump?.cancel()
        pump = nil
        mailbox.removeAll()
        resumeFrameWaiter(with: .failure(.disconnected))
        await transport.disconnect()
    }
    
    // MARK: - Frame pump and mailbox
    
    private func startPump(stream: AsyncStream<[UInt8]>, session: UInt64) -> Task<Void, Never> {
        Task {
            for await bytes in stream {
                guard session == sessionID else { return }
                handle(bytes)
            }
            guard session == sessionID else { return }
            pump = nil
            state = .disconnected
            mailbox.removeAll()
            resumeFrameWaiter(with: .failure(.disconnected))
        }
    }
    
    private func handle(_ bytes: [UInt8]) {
        // A malformed device frame is noise, not a failure of the request.
        guard let parsed = try? SysExFrame.parse(bytes) else { return }
        switch parsed {
        case .debug(let frame):
            halted = frame.text
            debugCount &+= 1
            deliver(parsed)
        case .response:
            deliver(parsed)
        case .request, .unrelated:
            break
        }
    }
    
    private func deliver(_ frame: ParsedFrame) {
        if frameWaiter != nil {
            resumeFrameWaiter(with: .success(frame))
            return
        }
        if Self.isDebug(frame) {
            mailbox.removeAll(where: Self.isDebug)
        }
        if mailbox.count >= Self.mailboxLimit, let evictable = mailbox.firstIndex(where: { !Self.isDebug($0) }) {
            mailbox.remove(at: evictable)
        }
        mailbox.append(frame)
    }
    
    private static func isDebug(_ frame: ParsedFrame) -> Bool {
        if case .debug = frame { return true }
        return false
    }
    
    /// `nil` means the deadline passed. Single consumer: only the gate holder
    /// (or `connect()` before the session is usable) may wait.
    func nextFrame(until deadline: ContinuousClock.Instant) async -> Result<ParsedFrame, KRError>? {
        if !mailbox.isEmpty {
            return .success(mailbox.removeFirst())
        }
        if state == .disconnected {
            return .failure(.disconnected)
        }
        if ContinuousClock.now >= deadline {
            return nil
        }
        let token = nextToken
        nextToken &+= 1
        return await withCheckedContinuation { continuation in
            resumeFrameWaiter(with: .failure(.disconnected))
            let timer = Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                expireFrameWaiter(token: token)
            }
            frameWaiter = FrameWaiter(token: token, continuation: continuation, timer: timer)
        }
    }
    
    private func resumeFrameWaiter(with result: Result<ParsedFrame, KRError>?) {
        guard let waiter = frameWaiter else { return }
        frameWaiter = nil
        waiter.timer.cancel()
        waiter.continuation.resume(returning: result)
    }
    
    private func expireFrameWaiter(token: UInt64) {
        guard frameWaiter?.token == token else { return }
        resumeFrameWaiter(with: nil)
    }
    
    // MARK: - FIFO gate
    
    /// Not re-entrant: the body must call `performRequest`, never `request`.
    func withGate<T>(_ body: () async throws(KRError) -> T) async throws(KRError) -> T {
        let session = sessionID
        try await acquireGate()
        defer { releaseGate() }
        holderSession = session
        return try await body()
    }
    
    private func acquireGate() async throws(KRError) {
        if Task.isCancelled {
            throw KRError.cancelled
        }
        guard isBusy else {
            isBusy = true
            return
        }
        let id = nextGateID
        nextGateID &+= 1
        let result: Result<Void, KRError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gateQueue.append(GateWaiter(id: id, continuation: continuation))
                if Task.isCancelled {
                    cancelGateWaiter(id: id)
                }
            }
        } onCancel: {
            Task { await self.cancelGateWaiter(id: id) }
        }
        try result.get()
    }
    
    private func cancelGateWaiter(id: UInt64) {
        guard let index = gateQueue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = gateQueue.remove(at: index)
        waiter.continuation.resume(returning: .failure(.cancelled))
    }
    
    private func releaseGate() {
        guard !gateQueue.isEmpty else {
            isBusy = false
            return
        }
        gateQueue.removeFirst().continuation.resume(returning: .success(()))
    }
}
