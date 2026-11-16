//
//  FileClientReadTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Testing
import KRCore
import KRSim
import KRWire
@testable import KRFile

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileClientReadTests {
    private static func payloads(_ transport: SimTransport) async -> [[UInt8]] {
        var result: [[UInt8]] = []
        for frame in await transport.sentFrames {
            if case .request(let request)? = try? SysExFrame.parse(frame) {
                result.append(request.payload)
            }
        }
        return result
    }
    
    private static func error(of operation: () async throws -> Void) async -> KRError? {
        do {
            try await operation()
            return nil
        } catch {
            return error as? KRError
        }
    }
    
    private static func connected(
        nodes: [SimNode] = [],
        configuration: FileClientConfiguration = SimHarness.configuration(),
        interruptedTransfer: Bool = false,
        onChange: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> (client: FileClient, transport: SimTransport) {
        let pair = SimHarness.make(
            nodes: nodes,
            configuration: configuration,
            interruptedTransfer: interruptedTransfer,
            onInterruptedTransferChange: onChange
        )
        try await pair.client.connect()
        return pair
    }
    
    private static func sample(_ slot: UInt16, count: Int) -> SimNode {
        SimFileSystem.sample(slot: slot, pcm: SimHarness.bytes(count: count, seed: UInt32(slot)))
    }
    
    // MARK: - GET through KRSim
    
    @Test func readsLargeFileByteExactWithoutOverread() async throws {
        let node = Self.sample(56, count: 46876)
        let (client, transport) = try await Self.connected(nodes: [node])
        let content = try await client.read(fid: 56)
        #expect(content.data == node.data)
        #expect(content.name == "056.pcm")
        #expect(content.flags == SimFileSystem.sampleFlags)
        let sent = await Self.payloads(transport)
        #expect(sent.filter { $0.starts(with: [0x03, 0x00]) }.count == 1)
        #expect(sent.filter { $0.starts(with: [0x03, 0x01]) }.count == 145)
        #expect(!sent.contains([0x03, 0x01, 0x00, 0x91]))
        #expect(await transport.device.isLooping == false)
        #expect(await client.transferInterrupted == false)
    }
    
    @Test(arguments: [(324, 1), (325, 2), (0, 0)])
    func sendsOnlyNeededPages(size: Int, pages: Int) async throws {
        let node = Self.sample(7, count: size)
        let (client, transport) = try await Self.connected(nodes: [node])
        let content = try await client.read(fid: 7)
        #expect(content.data == node.data)
        let sent = await Self.payloads(transport)
        #expect(sent.filter { $0.starts(with: [0x03, 0x01]) }.count == pages)
    }
    
    @Test func reportsIncreasingProgress() async throws {
        let (client, _) = try await Self.connected(nodes: [Self.sample(9, count: 1000)])
        let box = LockedBox<[TransferProgress]>([])
        _ = try await client.read(fid: 9) { value in box.update { $0.append(value) } }
        let values = box.value
        #expect(values.map(\.completed) == [324, 648, 972, 1000])
        #expect(values.last == TransferProgress(completed: 1000, total: 1000))
    }
    
    @Test func unknownFileIsACleanRejection() async throws {
        let (client, _) = try await Self.connected()
        let failure = await Self.error { _ = try await client.read(fid: 4242) }
        #expect(failure == .statusRejected(status: 1, reason: "invalid id"))
        #expect(await client.transferInterrupted == false)
    }
    
    @Test(arguments: [[UInt8]([0x03, 0x01]), [0x03, 0x00]])
    func silentDeviceTimesOutAndLocks(opcode: [UInt8]) async throws {
        let (client, transport) = try await Self.connected(nodes: [Self.sample(5, count: 700)])
        await transport.inject(.silence(opcode: opcode))
        let failure = await Self.error { _ = try await client.read(fid: 5) }
        guard case .timeout? = failure else {
            Issue.record("expected timeout, got \(String(describing: failure))")
            return
        }
        #expect(await client.transferInterrupted == true)
    }
    
    // MARK: - GET against a scripted device
    
    private static func reply(to frame: [UInt8], raw: [UInt8]) -> [[UInt8]] {
        [TestFrames.response(id: TestFrames.requestID(of: frame), raw: raw)]
    }
    
    private static func scripted(
        open: [UInt8]?,
        page: @escaping @Sendable (UInt16) -> [UInt8]?
    ) -> FakeTransport.Responder {
        { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame) else { return [] }
            let body = request.payload
            if body.starts(with: [0x03, 0x00]), let open {
                return reply(to: frame, raw: open)
            }
            if body.starts(with: [0x03, 0x01]), body.count >= 4 {
                let index = UInt16(body[2]) << 8 | UInt16(body[3])
                if let raw = page(index) {
                    return reply(to: frame, raw: raw)
                }
            }
            return []
        }
    }
    
    private static let openPayload: [UInt8] = [0x00, 0x38, 0x1D, 0x00, 0x00, 0x02, 0x00, 0x41, 0x00]
    
    private static func connectedFake(
        responder: @escaping FakeTransport.Responder,
        pageDelay: Duration = .milliseconds(1),
        onChange: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> (client: FileClient, transport: FakeTransport) {
        var configuration = SimHarness.configuration()
        configuration.pageDelay = pageDelay
        let transport = FakeTransport(responder: responder, autoReplyInit: true)
        let client = FileClient(
            transport: transport,
            product: .ep133,
            configuration: configuration,
            onInterruptedTransferChange: onChange
        )
        try await client.connect()
        return (client, transport)
    }
    
    @Test func wrongPageEchoFailsAndLocks() async throws {
        let responder = Self.scripted(open: Self.openPayload) { _ in [0x00, 0x01] + [UInt8](repeating: 1, count: 324) }
        let (client, _) = try await Self.connectedFake(responder: responder)
        let failure = await Self.error { _ = try await client.read(fid: 56) }
        #expect(failure == .malformedResponse(reason: "data page 1, expected 0"))
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func wrongOpenFidEchoFailsAndLocks() async throws {
        let responder = Self.scripted(open: Self.openPayload) { _ in nil }
        let (client, transport) = try await Self.connectedFake(responder: responder)
        let failure = await Self.error { _ = try await client.read(fid: 57) }
        guard case .malformedResponse? = failure else {
            Issue.record("expected malformedResponse, got \(String(describing: failure))")
            return
        }
        #expect(await transport.sentFrames.count == 1)
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func shortOpenPayloadFailsAndLocks() async throws {
        let responder = Self.scripted(open: [0x00, 0x38, 0x1D]) { _ in nil }
        let (client, _) = try await Self.connectedFake(responder: responder)
        let failure = await Self.error { _ = try await client.read(fid: 56) }
        guard case .malformedResponse? = failure else {
            Issue.record("expected malformedResponse, got \(String(describing: failure))")
            return
        }
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func shortDataFailsWithoutExtraPages() async throws {
        // Size 512 needs 2 pages; the device answers the last one with too few bytes.
        let open: [UInt8] = [0x00, 0x38, 0x1D, 0x00, 0x00, 0x02, 0x00, 0x41, 0x00]
        let responder = Self.scripted(open: open) { index in
            [0x00, UInt8(index)] + [UInt8](repeating: 1, count: index == 0 ? 324 : 10)
        }
        let (client, transport) = try await Self.connectedFake(responder: responder)
        let failure = await Self.error { _ = try await client.read(fid: 56) }
        guard case .malformedResponse(let reason)? = failure else {
            Issue.record("expected malformedResponse, got \(String(describing: failure))")
            return
        }
        #expect(reason.contains("short read"))
        #expect(await transport.sentFrames.count == 3)
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func cancelBetweenPagesStopsAndLocks() async throws {
        let responder = Self.scripted(open: Self.openPayload) { index in
            [0x00, UInt8(index)] + [UInt8](repeating: 1, count: 324)
        }
        let (client, transport) = try await Self.connectedFake(responder: responder, pageDelay: .seconds(5))
        let task = Task { try await client.read(fid: 56) }
        await transport.waitForSent(count: 2)
        task.cancel()
        let failure = await Self.error { _ = try await task.value }
        #expect(failure == .cancelled)
        #expect(await transport.sentFrames.count == 2)
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func cancelWhileWaitingForOpenLocks() async throws {
        let responder = Self.scripted(open: nil) { _ in nil }
        let (client, transport) = try await Self.connectedFake(responder: responder)
        let task = Task { try await client.read(fid: 56) }
        await transport.waitForSent(count: 1)
        task.cancel()
        let failure = await Self.error { _ = try await task.value }
        #expect(failure == .cancelled)
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func unplugWhileWaitingForPageLocks() async throws {
        let responder = Self.scripted(open: Self.openPayload) { _ in nil }
        let (client, transport) = try await Self.connectedFake(responder: responder)
        let task = Task { try await client.read(fid: 56) }
        await transport.waitForSent(count: 2)
        await transport.finish()
        let failure = await Self.error { _ = try await task.value }
        #expect(failure == .disconnected)
        #expect(await client.transferInterrupted == true)
    }
    
    // MARK: - Interrupted-transfer lock
    
    @Test func lockBlocksReadAndPlayButNotSafeCommands() async throws {
        let node = SimNode(
            fid: 56, parent: 1000, flags: SimFileSystem.sampleFlags, name: "056.pcm",
            data: SimHarness.bytes(count: 700), metadata: ["name": "\"kick\""]
        )
        let (client, transport) = try await Self.connected(nodes: [node])
        await transport.inject(.silence(opcode: [0x03, 0x01]))
        _ = await Self.error { _ = try await client.read(fid: 56) }
        let before = await transport.sentFrames.count
        #expect(await Self.error { _ = try await client.read(fid: 56) } == .transferInterrupted)
        #expect(await Self.error { try await client.play(fid: 56) } == .transferInterrupted)
        #expect(await transport.sentFrames.count == before)
        #expect(try await client.list(node: 1000).count == 1)
        #expect(try await client.stat(fid: 56).fid == 56)
        #expect(try await client.metadata(fid: 56) == "{\"name\":\"kick\"}")
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func lockSurvivesReconnectUntilCleared() async throws {
        let (client, transport) = try await Self.connected(nodes: [Self.sample(5, count: 700)])
        await transport.inject(.silence(opcode: [0x03, 0x01]))
        _ = await Self.error { _ = try await client.read(fid: 5) }
        let whileConnected = await Self.error { try await client.clearInterruptedTransfer() }
        #expect(whileConnected == .invalidArgument(reason: "disconnect first"))
        await client.disconnect()
        try await client.connect()
        #expect(await client.transferInterrupted == true)
        await client.disconnect()
        try await client.clearInterruptedTransfer()
        #expect(await client.transferInterrupted == false)
    }
    
    // MARK: - D5 persistence hooks
    
    @Test func initialLockBlocksRead() async throws {
        let (client, transport) = try await Self.connected(
            nodes: [Self.sample(5, count: 10)],
            interruptedTransfer: true
        )
        let before = await transport.sentFrames.count
        #expect(await Self.error { _ = try await client.read(fid: 5) } == .transferInterrupted)
        #expect(await transport.sentFrames.count == before)
    }
    
    @Test func callbackFiresBeforeOpenAndClearsOnSuccess() async throws {
        let events = LockedBox<[Bool]>([])
        let atOpen = LockedBox<[Bool]>([])
        let size0: [UInt8] = [0x00, 0x38, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00]
        let zeroSized: FakeTransport.Responder = { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame),
                  request.payload.starts(with: [0x03, 0x00]) else { return [] }
            atOpen.update { $0 = events.value }
            return Self.reply(to: frame, raw: size0)
        }
        let (client, _) = try await Self.connectedFake(responder: zeroSized) { value in
            events.update { $0.append(value) }
        }
        _ = try await client.read(fid: 56)
        #expect(atOpen.value == [true])
        #expect(events.value == [true, false])
    }
    
    @Test func cancelBeforeOpenWasSentNeverLocks() async throws {
        let events = LockedBox<[Bool]>([])
        let initCount = LockedBox(0)
        let responder: FakeTransport.Responder = { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame),
                  request.payload.first == 0x01 else { return [] }
            let index = initCount.value
            initCount.update { $0 += 1 }
            return index == 0 ? Self.reply(to: frame, raw: FakeTransport.initReplyPayload) : []
        }
        var configuration = SimHarness.configuration()
        configuration.idleReinit = .zero
        let transport = FakeTransport(responder: responder)
        let client = FileClient(
            transport: transport,
            product: .ep133,
            configuration: configuration
        ) { value in events.update { $0.append(value) } }
        try await client.connect()
        let task = Task { try await client.read(fid: 56) }
        await transport.waitForSent(count: 2)
        task.cancel()
        let held = try #require(await transport.sentFrames.last)
        await transport.reply(Self.reply(to: held, raw: FakeTransport.initReplyPayload))
        #expect(await Self.error { _ = try await task.value } == .cancelled)
        var sent: [[UInt8]] = []
        for frame in await transport.sentFrames {
            if case .request(let request)? = try? SysExFrame.parse(frame) {
                sent.append(request.payload)
            }
        }
        #expect(!sent.contains { $0.starts(with: [0x03, 0x00]) })
        #expect(await client.transferInterrupted == false)
        #expect(events.value.isEmpty)
        await client.disconnect()
    }
    
    @Test func clearDuringASuspendedOpenSendStillLocks() async throws {
        let events = LockedBox<[Bool]>([])
        let transport = FakeTransport(autoReplyInit: true)
        var configuration = SimHarness.configuration()
        configuration.idleReinit = .zero
        let client = FileClient(
            transport: transport,
            product: .ep133,
            configuration: configuration
        ) { value in events.update { $0.append(value) } }
        try await client.connect()
        await transport.holdSend { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame) else { return false }
            return request.payload.starts(with: [0x03, 0x00])
        }
        let task = Task { try await client.read(fid: 56) }
        await transport.waitForHeldSend()
        await client.disconnect()
        try await client.clearInterruptedTransfer()
        await transport.releaseHeldSend()
        #expect(await Self.error { _ = try await task.value } == .disconnected)
        #expect(await client.transferInterrupted)
        #expect(events.value == [true, false, true])
    }

    @Test func cleanOpenRejectionReportsFalseToTheCallback() async throws {
        let events = LockedBox<[Bool]>([])
        let (client, _) = try await Self.connected { value in events.update { $0.append(value) } }
        let failure = await Self.error { _ = try await client.read(fid: 4242) }
        #expect(failure == .statusRejected(status: 1, reason: "invalid id"))
        #expect(events.value == [true, false])
    }
    
    @Test func clearInterruptedTransferReportsFalseToTheCallback() async throws {
        let events = LockedBox<[Bool]>([])
        let (client, _) = try await Self.connected(interruptedTransfer: true) { value in
            events.update { $0.append(value) }
        }
        await client.disconnect()
        try await client.clearInterruptedTransfer()
        #expect(await client.transferInterrupted == false)
        #expect(events.value == [false])
    }
    
    @Test func callbackStaysTrueWhenCancelled() async throws {
        let events = LockedBox<[Bool]>([])
        var configuration = SimHarness.configuration()
        configuration.pageDelay = .seconds(5)
        let (client, transport) = try await Self.connected(
            nodes: [Self.sample(5, count: 1000)],
            configuration: configuration
        ) { value in events.update { $0.append(value) } }
        let task = Task { try await client.read(fid: 5) }
        await transport.waitForSent(count: 3)
        task.cancel()
        #expect(await Self.error { _ = try await task.value } == .cancelled)
        #expect(events.value == [true])
    }
    
    // MARK: - METADATA get
    
    @Test func metadataFullKeyedAndMultiPage() async throws {
        let long = String(repeating: "x", count: 700)
        let node = SimNode(
            fid: 3, parent: 1000, flags: SimFileSystem.sampleFlags, name: "003.pcm",
            metadata: ["name": "\"kick\"", "sound.pan": "-3", "note": "\"\(long)\""]
        )
        let plain = SimNode(fid: 4, parent: 1000, flags: SimFileSystem.sampleFlags, name: "004.pcm")
        let (client, _) = try await Self.connected(nodes: [node, plain])
        #expect(try await client.metadata(fid: 3, key: "name") == "{\"name\":\"kick\"}")
        let full = try await client.metadata(fid: 3)
        #expect(full == "{\"name\":\"kick\",\"note\":\"\(long)\",\"sound.pan\":-3}")
        #expect(full.utf8.count > 700)
        #expect(try await client.metadata(fid: 4) == "{}")
    }
    
    @Test func metadataRejectsKeyWithNULBeforeSending() async throws {
        let (client, transport) = try await Self.connected()
        let before = await transport.sentFrames.count
        let failure = await Self.error { _ = try await client.metadata(fid: 1, key: "a\u{0}b") }
        guard case .invalidArgument? = failure else {
            Issue.record("expected invalidArgument, got \(String(describing: failure))")
            return
        }
        #expect(await transport.sentFrames.count == before)
    }
    
    // MARK: - PLAY
    
    @Test func playRecordsFidAndRejectsUnknown() async throws {
        let (client, transport) = try await Self.connected(nodes: [Self.sample(56, count: 10)])
        try await client.play(fid: 56)
        #expect(await transport.device.playedFIDs == [56])
        #expect(await Self.error { try await client.play(fid: 4242) } == .statusRejected(status: 1, reason: "invalid id"))
    }
    
    // MARK: - Debug and ordering
    
    @Test func debugLoopMidGetHaltsAndLocks() async throws {
        let (client, transport) = try await Self.connected(nodes: [Self.sample(5, count: 700)])
        await transport.inject(.debugLoop(onOpcode: [0x03, 0x01], text: "err 82 test"))
        let failure = await Self.error { _ = try await client.read(fid: 5) }
        guard case .deviceDebugFrame? = failure else {
            Issue.record("expected deviceDebugFrame, got \(String(describing: failure))")
            return
        }
        #expect(await client.isHalted)
        #expect(await client.transferInterrupted == true)
        let before = await transport.sentFrames.count
        _ = await Self.error { _ = try await client.read(fid: 5) }
        _ = await Self.error { _ = try await client.stat(fid: 5) }
        #expect(await transport.sentFrames.count == before)
        await client.disconnect()
    }
    
    @Test func concurrentStatWaitsForTheWholeRead() async throws {
        let (client, transport) = try await Self.connected(nodes: [Self.sample(5, count: 20 * 324)])
        let reading = Task { try await client.read(fid: 5) }
        await transport.waitForSent(count: 2)
        let stating = Task { try await client.stat(fid: 5) }
        _ = try await reading.value
        _ = try await stating.value
        let sent = await Self.payloads(transport)
        let lastPage = sent.lastIndex { $0.starts(with: [0x03, 0x01]) }
        let stat = sent.firstIndex { $0.first == 0x0B }
        #expect(lastPage != nil && stat != nil && lastPage! < stat!)
    }
}
