//
//  FileClientRequestTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
import KRCore
import KRWire
@testable import KRFile

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileClientRequestTests {
    private let statRequest: [UInt8] = [0x0B, 0x00, 0x38]
    
    private func configuration(
        timeout: Duration = .milliseconds(150),
        drain: Duration = .milliseconds(50)
    ) -> FileClientConfiguration {
        FileClientConfiguration(
            requestTimeout: timeout,
            debugGrace: .milliseconds(500),
            drainWindow: drain,
            haltedPreflight: .milliseconds(300)
        )
    }
    
    private static let echo: FakeTransport.Responder = { frame in
        [TestFrames.response(id: TestFrames.requestID(of: frame), raw: [0x01, 0x02])]
    }
    
    private func connectedClient(
        _ transport: FakeTransport,
        product: Product = .ep133,
        timeout: Duration = .milliseconds(150)
    ) async throws -> FileClient {
        let client = FileClient(transport: transport, product: product, configuration: configuration(timeout: timeout))
        try await client.connect()
        return client
    }
    
    private func attempt(_ client: FileClient, _ raw: [UInt8]) async -> Result<[UInt8], KRError> {
        do throws(KRError) {
            return .success(try await client.request(raw))
        } catch {
            return .failure(error)
        }
    }
    
    private func attemptConnect(_ client: FileClient) async -> KRError? {
        do throws(KRError) {
            try await client.connect()
            return nil
        } catch {
            return error
        }
    }
    
    private func replyFrame(to index: Int, on transport: FakeTransport, raw: [UInt8]) async {
        let sent = await transport.sentFrames[index]
        await transport.reply([TestFrames.response(id: TestFrames.requestID(of: sent), raw: raw)])
    }
    
    private func waitUntilHalted(_ client: FileClient) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if await client.isHalted { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await client.isHalted
    }
    
    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
    
    private func parsed(_ frame: [UInt8]) throws -> ParsedFrame {
        try SysExFrame.parse(frame)
    }
    
    // MARK: - Matching and ids
    
    @Test func returnsPayloadAndSkipsUnrelatedFrames() async throws {
        let responder: FakeTransport.Responder = { frame in
            let id = TestFrames.requestID(of: frame)
            let request = SysExFrame.fileRequest(product: .ep133, id: RequestID(id), payload: [0x01])
            return [
                TestFrames.response(id: id &+ 1, raw: [0x09]),
                request,
                [0xF0, 0x00, 0x20, 0x76, 0x33, 0x41, 0x00, 0x00, 0x05, 0xF7],
                [0xF0, 0x7E, 0x7F, 0x06, 0x02, 0x00, 0x20, 0x76, 0x33, 0x00, 0x01, 0x00, 0x00, 0x00, 0xF7],
                [0xF0, 0x00, 0x20, 0x76, 0x33, 0xF7],
                TestFrames.response(id: id, raw: [0xAA, 0xBB])
            ]
        }
        let transport = FakeTransport(responder: responder, autoReplyInit: true)
        let client = try await connectedClient(transport)
        let result = await attempt(client, statRequest)
        #expect(result == .success([0xAA, 0xBB]))
    }
    
    @Test func idsAdvanceFromStartValue() async throws {
        let transport = FakeTransport(responder: Self.echo, autoReplyInit: true)
        let client = try await connectedClient(transport)
        for _ in 0..<3 {
            _ = await attempt(client, statRequest)
        }
        let sent = await transport.sentFrames
        #expect(sent.count == 3)
        #expect(Array(sent[0].prefix(9)) == [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x01, 0x05])
        #expect(sent.map { Array($0[6...7]) } == [[0x66, 0x01], [0x66, 0x02], [0x66, 0x03]])
        #expect(sent.map(TestFrames.requestID(of:)) == [0x301, 0x302, 0x303])
    }
    
    @Test func frameUsesConfiguredProduct() async throws {
        let transport = FakeTransport(responder: Self.echo, autoReplyInit: true)
        let client = try await connectedClient(transport, product: .ep40)
        _ = await attempt(client, statRequest)
        let sent = await transport.sentFrames
        #expect(sent[0][4] == 0x3C)
    }
    
    @Test func rejectedStatusThrowsAndClientStaysUsable() async throws {
        let rejecting: FakeTransport.Responder = { frame in
            [TestFrames.response(id: TestFrames.requestID(of: frame), status: 1, raw: Array("invalid id".utf8))]
        }
        let transport = FakeTransport(responder: rejecting, autoReplyInit: true)
        let client = try await connectedClient(transport)
        let first = await attempt(client, statRequest)
        #expect(first == .failure(.statusRejected(status: 1, reason: "invalid id")))
        await transport.setResponder(Self.echo)
        let second = await attempt(client, statRequest)
        #expect(second == .success([0x01, 0x02]))
    }
    
    // MARK: - Debug
    
    @Test func debugFrameInsteadOfResponseHaltsClient() async throws {
        let text = "err pattern 213 2_5_1"
        let transport = FakeTransport(responder: { _ in [TestFrames.debug(product: .ep40, text: text)] }, autoReplyInit: true)
        let client = try await connectedClient(transport)
        let first = await attempt(client, statRequest)
        #expect(first == .failure(.deviceDebugFrame(text: text)))
        let second = await attempt(client, statRequest)
        #expect(second == .failure(.deviceDebugFrame(text: text)))
        #expect(await transport.sentFrames.count == 1)
    }
    
    @Test func debugFrameOfOtherProductStillHalts() async throws {
        let transport = FakeTransport(responder: { _ in [TestFrames.debug(product: .ep133, text: "err lfs 6327")] }, autoReplyInit: true)
        let client = try await connectedClient(transport, product: .ep40)
        let result = await attempt(client, statRequest)
        #expect(result == .failure(.deviceDebugFrame(text: "err lfs 6327")))
    }
    
    @Test func debugWhileIdleHaltsWithoutSending() async throws {
        let transport = FakeTransport(responder: Self.echo, autoReplyInit: true)
        let client = try await connectedClient(transport)
        await transport.emit(TestFrames.debug(text: "err idle"))
        #expect(await waitUntilHalted(client))
        let result = await attempt(client, statRequest)
        #expect(result == .failure(.deviceDebugFrame(text: "err idle")))
        #expect(await transport.sentFrames.isEmpty)
    }
    
    @Test func mailboxOverflowKeepsHalted() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport)
        await transport.emit(TestFrames.debug(text: "err mailbox"))
        for index in 0..<100 {
            await transport.emit(TestFrames.response(id: UInt16(index), raw: [0x01]))
        }
        #expect(await waitUntilHalted(client))
        let result = await attempt(client, statRequest)
        #expect(result == .failure(.deviceDebugFrame(text: "err mailbox")))
        #expect(await transport.sentFrames.isEmpty)
    }
    
    @Test func mailboxKeepsOnlyNewestDebugFrame() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport)
        for index in 0..<5 {
            await transport.emit(TestFrames.debug(text: "err \(index)"))
        }
        let newest = try parsed(TestFrames.debug(text: "err 4"))
        let settled = await waitUntil { await client.mailbox == [newest] }
        #expect(settled)
    }
    
    @Test func mailboxEvictsOldestResponseAndKeepsDebug() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport)
        await transport.emit(TestFrames.debug(text: "err evict"))
        for index in 0..<100 {
            await transport.emit(TestFrames.response(id: UInt16(index), raw: [0x01]))
        }
        let last = try parsed(TestFrames.response(id: 99, raw: [0x01]))
        let settled = await waitUntil { await client.mailbox.last == last }
        #expect(settled)
        let mailbox = await client.mailbox
        #expect(mailbox.count == 64)
        let debug = try parsed(TestFrames.debug(text: "err evict"))
        let oldest = try parsed(TestFrames.response(id: 37, raw: [0x01]))
        #expect(mailbox.first == debug)
        #expect(mailbox.dropFirst().first == oldest)
    }
    
    // MARK: - Timeout
    
    @Test func silentDeviceTimesOutAfterGraceWithoutRetry() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await attempt(client, statRequest)
        let elapsed = clock.now - start
        #expect(result == .failure(.timeout(requestID: 0x301)))
        #expect(elapsed >= .milliseconds(650))
        #expect(elapsed < .seconds(3))
        #expect(await transport.sentFrames.count == 1)
    }
    
    @Test func debugDuringGraceIsReported() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport)
        let task = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        try await Task.sleep(for: .milliseconds(300))
        await transport.emit(TestFrames.debug(text: "err grace"))
        #expect(await task.value == .failure(.deviceDebugFrame(text: "err grace")))
    }
    
    // MARK: - Queueing and cancellation
    
    @Test func concurrentRequestsAreSerializedFIFO() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .seconds(2))
        let first = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        let second = Task { await attempt(client, statRequest) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.sentFrames.count == 1)
        await replyFrame(to: 0, on: transport, raw: [0x01])
        await transport.waitForSent(count: 2)
        await replyFrame(to: 1, on: transport, raw: [0x02])
        #expect(await first.value == .success([0x01]))
        #expect(await second.value == .success([0x02]))
        let ids = await transport.sentFrames.map(TestFrames.requestID(of:))
        #expect(ids == [0x301, 0x302])
    }
    
    @Test func cancelledQueuedWaiterNeverSends() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .seconds(2))
        let first = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        let second = Task { await attempt(client, statRequest) }
        try await Task.sleep(for: .milliseconds(50))
        second.cancel()
        #expect(await second.value == .failure(.cancelled))
        await replyFrame(to: 0, on: transport, raw: [0x01])
        #expect(await first.value == .success([0x01]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.sentFrames.count == 1)
    }
    
    @Test func cancelledInFlightRequestKeepsGateUntilResponse() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .milliseconds(600))
        let first = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        first.cancel()
        let second = Task { await attempt(client, statRequest) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.sentFrames.count == 1)
        await replyFrame(to: 0, on: transport, raw: [0x01])
        #expect(await first.value == .success([0x01]))
        await transport.waitForSent(count: 2)
        await replyFrame(to: 1, on: transport, raw: [0x02])
        #expect(await second.value == .success([0x02]))
    }
    
    @Test func cancelledInFlightRequestExpiresWithoutGrace() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .milliseconds(150))
        let clock = ContinuousClock()
        let start = clock.now
        let first = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        first.cancel()
        let second = Task { await attempt(client, statRequest) }
        #expect(await first.value == .failure(.cancelled))
        #expect(clock.now - start < .milliseconds(600))
        await transport.waitForSent(count: 2)
        await replyFrame(to: 1, on: transport, raw: [0x02])
        #expect(await second.value == .success([0x02]))
    }
    
    @Test func randomCancellationNeitherHangsNorOverlaps() async throws {
        let transport = FakeTransport(responder: Self.echo, replyDelay: .milliseconds(1), autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .seconds(2))
        for index in 0..<50 {
            let task = Task { await attempt(client, statRequest) }
            try await Task.sleep(for: .microseconds((index % 7) * 400))
            task.cancel()
            let result = await task.value
            #expect(result == .success([0x01, 0x02]) || result == .failure(.cancelled))
        }
        let final = await attempt(client, statRequest)
        #expect(final == .success([0x01, 0x02]))
        #expect(await transport.maxInFlight <= 1)
    }
    
    @Test func queuedWaiterOfPreviousSessionNeverRunsInNewSession() async throws {
        let transport = FakeTransport(responder: Self.echo, autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .seconds(2))
        await transport.setResponder(nil)
        let first = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        let second = Task { await attempt(client, statRequest) }
        try await Task.sleep(for: .milliseconds(50))
        await replyFrame(to: 0, on: transport, raw: [0x01])
        await client.disconnect()
        await transport.setResponder(Self.echo)
        try await client.connect()
        let firstResult = await first.value
        #expect(firstResult == .success([0x01]) || firstResult == .failure(.disconnected))
        #expect(await second.value == .failure(.disconnected))
        #expect(await attempt(client, statRequest) == .success([0x01, 0x02]))
    }
    
    @Test func frameWaiterIsFailedWhenReplaced() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport)
        let first = Task { await client.nextFrame(until: .now + .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        let second = await client.nextFrame(until: .now + .milliseconds(100))
        #expect(await first.value == .failure(.disconnected))
        #expect(second == nil)
    }
    
    @Test func reconnectAtRequestTimeoutBoundaryDoesNotHang() async throws {
        for offset in stride(from: 130, through: 170, by: 5) {
            let transport = FakeTransport(autoReplyInit: true)
            let client = try await connectedClient(transport)
            let task = Task { await attempt(client, statRequest) }
            try await Task.sleep(for: .milliseconds(offset))
            await client.disconnect()
            try await client.connect()
            #expect(await task.value == .failure(.disconnected))
            await transport.setResponder(Self.echo)
            #expect(await attempt(client, statRequest) == .success([0x01, 0x02]))
            await client.disconnect()
        }
    }
    
    // MARK: - Disconnect
    
    @Test func streamEndWhileWaitingThrowsDisconnected() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .seconds(2))
        let task = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        await transport.finish()
        #expect(await task.value == .failure(.disconnected))
        #expect(await attempt(client, statRequest) == .failure(.disconnected))
    }
    
    @Test func streamEndWithQueuedWaitersFailsAllWithDisconnected() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .seconds(2))
        let first = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        let second = Task { await attempt(client, statRequest) }
        let third = Task { await attempt(client, statRequest) }
        try await Task.sleep(for: .milliseconds(50))
        await transport.finish()
        #expect(await first.value == .failure(.disconnected))
        #expect(await second.value == .failure(.disconnected))
        #expect(await third.value == .failure(.disconnected))
        #expect(await transport.sentFrames.count == 1)
    }
    
    @Test func requestBeforeConnectThrowsDisconnected() async {
        let client = FileClient(transport: FakeTransport(autoReplyInit: true), product: .ep133, configuration: configuration())
        #expect(await attempt(client, statRequest) == .failure(.disconnected))
    }
    
    @Test func connectTwiceThrowsAlreadyConnected() async throws {
        let client = try await connectedClient(FakeTransport(autoReplyInit: true))
        await #expect(throws: KRError.alreadyConnected) {
            try await client.connect()
        }
    }
    
    @Test func disconnectFailsWaitingAndQueuedRequests() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .seconds(2))
        let first = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        let second = Task { await attempt(client, statRequest) }
        try await Task.sleep(for: .milliseconds(50))
        await client.disconnect()
        #expect(await first.value == .failure(.disconnected))
        #expect(await second.value == .failure(.disconnected))
        #expect(await transport.sentFrames.count == 1)
    }
    
    // MARK: - Drain and reconnect
    
    @Test func connectDrainsStaleFrames() async throws {
        let stale = TestFrames.response(id: 0x300, raw: [0x00, 0x00, 0x00, 0x04, 0x00])
        let transport = FakeTransport(initialFrames: [stale], autoReplyInit: true)
        let client = try await connectedClient(transport, timeout: .seconds(2))
        #expect(await client.chunkSize == 512)
        let task = Task { await attempt(client, statRequest) }
        await transport.waitForSent(count: 1)
        await replyFrame(to: 0, on: transport, raw: Array("NEW".utf8))
        #expect(await task.value == .success(Array("NEW".utf8)))
    }
    
    @Test func connectDoesNotFinishBeforeDrainWindow() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(drain: .milliseconds(300)))
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { await attemptConnect(client) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.initFrames.isEmpty)
        let failure = await task.value
        #expect(failure == nil)
        #expect(clock.now - start >= .milliseconds(290))
        #expect(await transport.initFrames.count == 1)
    }
    
    @Test func disconnectDuringConnectFailsConnectAndAllowsReconnect() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(drain: .milliseconds(300)))
        let task = Task { await attemptConnect(client) }
        try await Task.sleep(for: .milliseconds(100))
        await client.disconnect()
        let failure = await task.value
        #expect(failure == .disconnected)
        #expect(await transport.initFrames.isEmpty)
        try await client.connect()
        #expect(await attempt(client, statRequest) == .failure(.timeout(requestID: 0x301)))
    }
    
    @Test func cancellingConnectTaskAbortsAndAllowsReconnect() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(drain: .milliseconds(300)))
        let task = Task { await attemptConnect(client) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let failure = await task.value
        #expect(failure == .cancelled)
        #expect(await attempt(client, statRequest) == .failure(.disconnected))
        #expect(await transport.disconnectCount == 1)
        try await client.connect()
    }
    
    @Test func debugDuringDrainFailsConnect() async throws {
        let transport = FakeTransport(initialFrames: [TestFrames.debug(text: "err boot")], autoReplyInit: true)
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        await #expect(throws: KRError.deviceDebugFrame(text: "err boot")) {
            try await client.connect()
        }
        #expect(await client.isHalted)
        #expect(await transport.connectCount == 1)
        #expect(await transport.disconnectCount == 1)
    }
    
    @Test func haltedStateClearsOnlyAfterCleanPreflight() async throws {
        let transport = FakeTransport(responder: { _ in [TestFrames.debug(text: "err halt")] }, autoReplyInit: true)
        let client = try await connectedClient(transport)
        #expect(await attempt(client, statRequest) == .failure(.deviceDebugFrame(text: "err halt")))
        await client.disconnect()
        await transport.setResponder(Self.echo)
        let clock = ContinuousClock()
        let start = clock.now
        try await client.connect()
        #expect(clock.now - start >= .milliseconds(300))
        #expect(await !client.isHalted)
        #expect(await attempt(client, statRequest) == .success([0x01, 0x02]))
    }
    
    @Test func haltedStateSurvivesReconnectWhenDeviceStillLoops() async throws {
        let transport = FakeTransport(responder: { _ in [TestFrames.debug(text: "err loop")] }, autoReplyInit: true)
        let client = try await connectedClient(transport)
        _ = await attempt(client, statRequest)
        await client.disconnect()
        await transport.setInitialFrames([TestFrames.debug(text: "err loop")])
        await #expect(throws: KRError.deviceDebugFrame(text: "err loop")) {
            try await client.connect()
        }
        #expect(await client.isHalted)
    }
    
    @Test func previousSessionPumpDoesNotAffectNewSession() async throws {
        let transport = FakeTransport(responder: Self.echo, deferFinishOnDisconnect: true, autoReplyInit: true)
        let client = try await connectedClient(transport)
        await client.disconnect()
        try await client.connect()
        await transport.emitOnPreviousStreams(TestFrames.debug(text: "err stale"))
        await transport.finishPreviousStream()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !client.isHalted)
        #expect(await attempt(client, statRequest) == .success([0x01, 0x02]))
    }
}
