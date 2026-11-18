//
//  FileClientWriteTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Testing
import KRCore
import KRSim
import KRWire
@testable import KRFile
@_spi(UnsafeDeviceLab) import KRFile

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileClientWriteTests {
    private static func payloads(_ frames: [[UInt8]]) -> [[UInt8]] {
        frames.compactMap { frame in
            if case .request(let request)? = try? SysExFrame.parse(frame) {
                return request.payload
            }
            return nil
        }
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
        chunkSize: UInt32 = 512
    ) async throws -> (client: FileClient, transport: SimTransport) {
        let pair = SimHarness.make(nodes: nodes, chunkSize: chunkSize)
        try await pair.client.connect()
        return pair
    }
    
    private static func sample(_ slot: UInt16, count: Int) -> SimNode {
        SimFileSystem.sample(slot: slot, pcm: SimHarness.bytes(count: count, seed: UInt32(slot)))
    }
    
    // MARK: - PUT through KRSim
    
    @Test func writesThroughInitOpenPagesEofAndInit() async throws {
        let (client, transport) = try await Self.connected()
        let data = SimHarness.bytes(count: 1000)
        let box = LockedBox<[TransferProgress]>([])
        try await client.write(
            fid: 56, parent: 1000, name: "056.pcm", flags: .sound, data: data
        ) { value in box.update { $0.append(value) } }
        let sent = Self.payloads(await transport.sentFrames)
        // The first INIT belongs to connect().
        #expect(sent.count == 8)
        #expect(sent[1].first == 0x01)
        // cmd, flags, fid 56, parent 1000, size 1000 (u32), name, NUL.
        let open: [UInt8] = [0x02, 0x00, 0x05, 0x00, 0x38, 0x03, 0xE8, 0x00, 0x00, 0x03, 0xE8]
            + Array("056.pcm".utf8) + [0x00]
        #expect(sent[2] == open)
        #expect(sent[3].count == 4 + 433 && sent[3].starts(with: [0x02, 0x01, 0x00, 0x00]))
        #expect(sent[4].count == 4 + 433 && sent[4].starts(with: [0x02, 0x01, 0x00, 0x01]))
        #expect(sent[5].count == 4 + 134 && sent[5].starts(with: [0x02, 0x01, 0x00, 0x02]))
        #expect(sent[6] == [0x02, 0x01, 0x00, 0x03])
        #expect(sent[7].first == 0x01)
        #expect(await transport.device.fileSystem.node(56)?.data == data)
        #expect(box.value.last == TransferProgress(completed: 1000, total: 1000))
        #expect(await client.transferInterrupted == false)
    }
    
    @Test(arguments: [(433, 1), (0, 0)])
    func pageCountsAtTheEdges(size: Int, eofPage: UInt8) async throws {
        let (client, transport) = try await Self.connected()
        try await client.write(
            fid: 7, parent: 1000, name: "007.pcm", flags: .sound, data: SimHarness.bytes(count: size)
        )
        let sent = Self.payloads(await transport.sentFrames)
        let dataPages = sent.filter { $0.starts(with: [0x02, 0x01]) }
        #expect(dataPages.count == Int(eofPage) + 1)
        #expect(dataPages.last == [0x02, 0x01, 0x00, eofPage])
        #expect(await transport.device.fileSystem.node(7)?.data.count == size)
    }
    
    @Test func storesProjectArchiveFlags() async throws {
        let (client, transport) = try await Self.connected()
        try await client.write(
            fid: 3000, parent: 2000, name: "01", flags: .projectArchive, data: SimHarness.bytes(count: 600)
        )
        #expect(await transport.device.fileSystem.node(3000)?.flags == 0x06)
    }
    
    @Test func usesLargerPagesForLargerChunk() async throws {
        let (client, transport) = try await Self.connected(chunkSize: 1024)
        try await client.write(
            fid: 8, parent: 1000, name: "008.pcm", flags: .sound, data: SimHarness.bytes(count: 900)
        )
        let sent = Self.payloads(await transport.sentFrames)
        #expect(sent.first { $0.starts(with: [0x02, 0x01, 0x00, 0x00]) }?.count == 4 + 881)
    }
    
    @Test func invalidNameSendsNothing() async throws {
        let (client, transport) = try await Self.connected()
        let before = await transport.sentFrames.count
        let failure = await Self.error {
            try await client.write(fid: 9, parent: 1000, name: "é.pcm", flags: .sound, data: [1])
        }
        guard case .invalidArgument? = failure else {
            Issue.record("expected invalidArgument, got \(String(describing: failure))")
            return
        }
        #expect(await transport.sentFrames.count == before)
    }
    
    @Test func oversizedInputsSendNothingEvenWhenTheSessionIsIdle() async throws {
        let (client, transport) = try await {
            let pair = SimHarness.make(configuration: SimHarness.configuration(idleReinit: .zero))
            try await pair.client.connect()
            return pair
        }()
        try await Task.sleep(for: .milliseconds(20))
        let before = await transport.sentFrames.count
        let longName = String(repeating: "a", count: 500)
        let writeFailure = await Self.error {
            try await client.write(fid: 9, parent: 1000, name: longName, flags: .sound, data: [1])
        }
        let json = "{\"a\":\"" + String(repeating: "x", count: 500) + "\"}"
        let metadataFailure = await Self.error { try await client.setMetadata(fid: 9, json: json) }
        for failure in [writeFailure, metadataFailure] {
            guard case .invalidArgument? = failure else {
                Issue.record("expected invalidArgument, got \(String(describing: failure))")
                return
            }
        }
        #expect(await transport.sentFrames.count == before)
        await client.disconnect()
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
        let (client, transport) = try await Self.connectedFake(autoReplyInit: false, onChange: { value in
            events.update { $0.append(value) }
        }, responder: responder)
        let task = Task { try await Self.write(client, data: [1, 2, 3]) }
        await transport.waitForSent(count: 2)
        task.cancel()
        let held = try #require(await transport.sentFrames.last)
        await transport.reply(Self.reply(to: held, raw: FakeTransport.initReplyPayload))
        #expect(await Self.error { try await task.value } == .cancelled)
        let sent = Self.payloads(await transport.sentFrames)
        #expect(!sent.contains { $0.starts(with: [0x02, 0x00]) })
        #expect(await client.transferInterrupted == false)
        #expect(events.value.isEmpty)
        await client.disconnect()
    }
    
    @Test func callbackWrapsACleanWrite() async throws {
        let events = LockedBox<[Bool]>([])
        let atOpen = LockedBox<[Bool]>([])
        let responder: FakeTransport.Responder = { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame) else { return [] }
            if request.payload.starts(with: [0x02, 0x00]) {
                atOpen.update { $0 = events.value }
                return Self.reply(to: frame, raw: [0x00, 0x38])
            }
            return Self.reply(to: frame)
        }
        let (client, _) = try await Self.connectedFake(onChange: { value in
            events.update { $0.append(value) }
        }, responder: responder)
        try await Self.write(client, data: [1, 2, 3])
        #expect(atOpen.value == [true])
        #expect(events.value == [true, false])
    }
    
    @Test func interruptedPutLeavesTheCallbackTrue() async throws {
        let events = LockedBox<[Bool]>([])
        let responder = Self.scripted { _, isEOF in isEOF ? nil : (0, []) }
        let (client, _) = try await Self.connectedFake(onChange: { value in
            events.update { $0.append(value) }
        }, responder: responder)
        _ = await Self.error { try await Self.write(client, data: [1, 2, 3]) }
        #expect(events.value == [true])
    }
    
    @Test func cleanPutOpenRejectionReportsFalse() async throws {
        let events = LockedBox<[Bool]>([])
        let responder = Self.scripted(open: nil) { _, _ in nil }
        let rejecting: FakeTransport.Responder = { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame),
                  request.payload.starts(with: [0x02, 0x00]) else { return responder(frame) }
            return Self.reply(to: frame, status: 1, raw: Array("nope".utf8))
        }
        let (client, _) = try await Self.connectedFake(onChange: { value in
            events.update { $0.append(value) }
        }, responder: rejecting)
        let failure = await Self.error { try await Self.write(client, data: [1]) }
        #expect(failure == .statusRejected(status: 1, reason: "nope"))
        #expect(events.value == [true, false])
    }
    
    @Test func cleanOpenRejectionDoesNotLock() async throws {
        let (client, _) = try await Self.connected()
        let failure = await Self.error {
            try await client.write(
                fid: 9, parent: 1000, name: "009.pcm", flags: FileCreateFlags(rawValue: 0x04), data: [1]
            )
        }
        #expect(failure == .statusRejected(status: 1, reason: "can only create files"))
        #expect(await client.transferInterrupted == false)
    }
    
    // MARK: - PUT against a scripted device
    
    private static func reply(to frame: [UInt8], status: UInt8 = 0, raw: [UInt8] = []) -> [[UInt8]] {
        [TestFrames.response(id: TestFrames.requestID(of: frame), status: status, raw: raw)]
    }
    
    private static func connectedFake(
        configuration: FileClientConfiguration = SimHarness.configuration(),
        autoReplyInit: Bool = true,
        onChange: (@Sendable (Bool) -> Void)? = nil,
        responder: @escaping FakeTransport.Responder
    ) async throws -> (client: FileClient, transport: FakeTransport) {
        var configuration = configuration
        configuration.transferTimeout = .milliseconds(150)
        let transport = FakeTransport(responder: responder, autoReplyInit: autoReplyInit)
        let client = FileClient(
            transport: transport,
            product: .ep133,
            configuration: configuration,
            onInterruptedTransferChange: onChange
        )
        try await client.connect()
        return (client, transport)
    }
    
    private static func scripted(
        open: [UInt8]? = [0x00, 0x38],
        data: @escaping @Sendable (_ page: UInt8, _ isEOF: Bool) -> (status: UInt8, raw: [UInt8])?
    ) -> FakeTransport.Responder {
        { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame) else { return [] }
            let body = request.payload
            if body.starts(with: [0x02, 0x00]) {
                return open.map { reply(to: frame, raw: $0) } ?? []
            }
            if body.starts(with: [0x02, 0x01]), body.count >= 4,
               let answer = data(body[3], body.count == 4) {
                return reply(to: frame, status: answer.status, raw: answer.raw)
            }
            return []
        }
    }
    
    private static func write(
        _ client: FileClient,
        data: [UInt8],
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        try await client.write(fid: 56, parent: 1000, name: "056.pcm", flags: .sound, data: data, progress: progress)
    }
    
    @Test func wrongOpenEchoFailsBeforeData() async throws {
        let responder = Self.scripted(open: [0x00, 0x39]) { _, _ in (0, []) }
        let (client, transport) = try await Self.connectedFake(responder: responder)
        let failure = await Self.error { try await Self.write(client, data: [1, 2, 3]) }
        guard case .malformedResponse? = failure else {
            Issue.record("expected malformedResponse, got \(String(describing: failure))")
            return
        }
        #expect(await transport.sentFrames.count == 1)
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func eofTimeoutLocks() async throws {
        let responder = Self.scripted { _, isEOF in isEOF ? nil : (0, []) }
        let (client, _) = try await Self.connectedFake(responder: responder)
        let failure = await Self.error { try await Self.write(client, data: [1, 2, 3]) }
        guard case .timeout? = failure else {
            Issue.record("expected timeout, got \(String(describing: failure))")
            return
        }
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func cancelAfterFirstPageStopsAndLocks() async throws {
        var configuration = SimHarness.configuration()
        configuration.pageDelay = .seconds(5)
        let responder = Self.scripted { _, _ in (0, []) }
        let (client, transport) = try await Self.connectedFake(configuration: configuration, responder: responder)
        let task = Task { try await Self.write(client, data: SimHarness.bytes(count: 1000)) }
        await transport.waitForSent(count: 2)
        task.cancel()
        #expect(await Self.error { try await task.value } == .cancelled)
        #expect(await transport.sentFrames.count == 2)
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func rejectedDataPageLocks() async throws {
        let responder = Self.scripted { _, _ in (1, Array("bad".utf8)) }
        let (client, _) = try await Self.connectedFake(responder: responder)
        let failure = await Self.error { try await Self.write(client, data: [1, 2, 3]) }
        #expect(failure == .statusRejected(status: 1, reason: "bad"))
        #expect(await client.transferInterrupted == true)
    }
    
    @Test func rejectedFirstInitSendsNoOpen() async throws {
        let initCount = LockedBox(0)
        let responder: FakeTransport.Responder = { frame in
            guard case .request(let request)? = try? SysExFrame.parse(frame),
                  request.payload.first == 0x01 else { return [] }
            let index = initCount.value
            initCount.update { $0 += 1 }
            return index == 0
                ? Self.reply(to: frame, raw: FakeTransport.initReplyPayload)
                : Self.reply(to: frame, status: 1, raw: Array("busy".utf8))
        }
        let (client, transport) = try await Self.connectedFake(autoReplyInit: false, responder: responder)
        let failure = await Self.error { try await Self.write(client, data: [1]) }
        #expect(failure == .statusRejected(status: 1, reason: "busy"))
        let sent = Self.payloads(await transport.sentFrames)
        #expect(!sent.contains { $0.starts(with: [0x02, 0x00]) })
        #expect(await client.transferInterrupted == false)
    }
    
    @Test func cancelAfterEofAckStillFinishesCleanly() async throws {
        let pending = LockedBox<Task<Void, any Error>?>(nil)
        let responder = Self.scripted { _, isEOF in isEOF ? nil : (0, []) }
        // The lock is released right after the EOF ack is consumed, so cancelling there
        // lands inside the commit phase (commit delay + final INIT).
        let (client, transport) = try await Self.connectedFake(onChange: { locked in
            if !locked {
                pending.value?.cancel()
            }
        }, responder: responder)
        let task = Task { try await Self.write(client, data: []) }
        pending.update { $0 = task }
        await transport.waitForSent(count: 2)
        let eof = try #require(await transport.sentFrames.last)
        await transport.reply(Self.reply(to: eof))
        #expect(await Self.error { try await task.value } == nil)
        #expect(task.isCancelled)
        #expect(await transport.initFrames.count == 3)
        #expect(await client.transferInterrupted == false)
    }
    
    // MARK: - DELETE and METADATA set through KRSim
    
    @Test func deleteRemovesTheNode() async throws {
        let (client, transport) = try await Self.connected(nodes: [Self.sample(56, count: 10), Self.sample(57, count: 10)])
        try await client.delete(fid: 56)
        let sent = Self.payloads(await transport.sentFrames)
        #expect(sent.contains([0x06, 0x00, 0x38]))
        #expect(try await client.list(node: 1000).map(\.id) == [57])
        let failure = await Self.error { try await client.delete(fid: 4242) }
        #expect(failure == .statusRejected(status: 1, reason: "invalid id"))
    }
    
    @Test func setMetadataMergesAndValidates() async throws {
        let (client, transport) = try await Self.connected(nodes: [Self.sample(56, count: 10)])
        try await client.setMetadata(fid: 56, json: "{\"name\":\"kick\"}")
        try await client.setMetadata(fid: 56, json: "{\"sound.pan\":-3}")
        #expect(try await client.metadata(fid: 56) == "{\"name\":\"kick\",\"sound.pan\":-3}")
        let before = await transport.sentFrames.count
        let long = "{\"a\":\"" + String(repeating: "x", count: 500) + "\"}"
        let failure = await Self.error { try await client.setMetadata(fid: 56, json: long) }
        guard case .invalidArgument? = failure else {
            Issue.record("expected invalidArgument, got \(String(describing: failure))")
            return
        }
        #expect(await transport.sentFrames.count == before)
    }
}
