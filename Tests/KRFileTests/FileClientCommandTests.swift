//
//  FileClientCommandTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
import KRCore
import KRWire
@testable import KRFile

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileClientCommandTests {
    private func configuration(
        idleReinit: Duration = .seconds(5),
        initFlags: UInt8 = 0x01
    ) -> FileClientConfiguration {
        FileClientConfiguration(
            requestTimeout: .milliseconds(500),
            debugGrace: .milliseconds(500),
            drainWindow: .milliseconds(20),
            haltedPreflight: .milliseconds(300),
            idleReinit: idleReinit,
            initFlags: initFlags
        )
    }
    
    private static func payload(of frame: [UInt8]) -> [UInt8] {
        guard case .request(let request)? = try? SysExFrame.parse(frame) else { return [] }
        return request.payload
    }
    
    private static func reply(to frame: [UInt8], status: UInt8 = 0, raw: [UInt8]) -> [[UInt8]] {
        [TestFrames.response(id: TestFrames.requestID(of: frame), status: status, raw: raw)]
    }
    
    /// Answers INIT with `chunk`, LIST with `pages[page]` (echo-only past the end) and STAT with `statPayload`.
    private static func device(
        chunk: [UInt8] = FakeTransport.initReplyPayload,
        pages: [[UInt8]] = [],
        statPayload: [UInt8] = FileVectors.statPayload56
    ) -> FakeTransport.Responder {
        { frame in
            let body = payload(of: frame)
            switch body.first {
            case 0x01:
                return reply(to: frame, raw: chunk)
            case 0x04:
                let page = Int(body[1]) << 8 | Int(body[2])
                let entries = page < pages.count ? pages[page] : []
                return reply(to: frame, raw: FileVectors.listPayload(page: UInt16(page), entries: entries))
            case 0x0B:
                return reply(to: frame, raw: statPayload)
            default:
                return []
            }
        }
    }
    
    private func attemptList(_ client: FileClient, node: UInt16 = FileNode.soundsID) async -> Result<[FileNode], KRError> {
        do throws(KRError) {
            return .success(try await client.list(node: node))
        } catch {
            return .failure(error)
        }
    }
    
    private func attemptStat(_ client: FileClient, fid: UInt16) async -> Result<FileStat, KRError> {
        do throws(KRError) {
            return .success(try await client.stat(fid: fid))
        } catch {
            return .failure(error)
        }
    }
    
    // MARK: - INIT
    
    @Test func connectSendsInitFrameAndReadsDefaultChunk() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        #expect(await transport.sentFrames == [FileVectors.initFrame])
        #expect(await client.chunkSize == 512)
    }
    
    @Test func connectStoresChunkSizeFromInitResponse() async throws {
        let transport = FakeTransport(responder: Self.device(chunk: [0x00, 0x00, 0x00, 0x04, 0x00]))
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        #expect(await client.chunkSize == 1024)
    }
    
    @Test func connectFallsBackTo512ForShortInitResponse() async throws {
        let transport = FakeTransport(responder: Self.device(chunk: [0x00]))
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        #expect(await client.chunkSize == 512)
    }
    
    @Test func connectUsesConfiguredInitFlags() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(initFlags: 0x00))
        try await client.connect()
        let sent = try #require(await transport.sentFrames.first)
        #expect(Self.payload(of: sent) == FileVectors.initRequestRead)
    }
    
    @Test func rejectedInitFailsConnectAndAllowsReconnect() async throws {
        let rejecting: FakeTransport.Responder = { frame in
            Self.reply(to: frame, status: 1, raw: Array("busy".utf8))
        }
        let transport = FakeTransport(responder: rejecting)
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        await #expect(throws: KRError.statusRejected(status: 1, reason: "busy")) {
            try await client.connect()
        }
        #expect(await transport.disconnectCount == 1)
        #expect(await !client.isHalted)
        #expect(await attemptStat(client, fid: 56) == .failure(.disconnected))
        await transport.setResponder(Self.device())
        try await client.connect()
        #expect(await attemptStat(client, fid: 56) == .success(FileVectors.stat56))
    }
    
    // MARK: - LIST
    
    @Test func listCollectsPagesInDeviceOrderUntilEchoOnlyPage() async throws {
        let pages = [
            FileVectors.entry001 + FileVectors.entryTest,
            FileVectors.entryTest + FileVectors.entry001
        ]
        let transport = FakeTransport(responder: Self.device(pages: pages))
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        let result = await attemptList(client)
        #expect(result == .success([
            FileVectors.node001, FileVectors.nodeTest, FileVectors.nodeTest, FileVectors.node001
        ]))
        let sent = await transport.sentFrames.dropFirst().map(Self.payload(of:))
        #expect(sent == [
            [0x04, 0x00, 0x00, 0x03, 0xE8],
            [0x04, 0x00, 0x01, 0x03, 0xE8],
            [0x04, 0x00, 0x02, 0x03, 0xE8]
        ])
    }
    
    @Test func listOfEmptyNodeReturnsEmptyAfterOneRequest() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        #expect(await attemptList(client, node: FileNode.projectsID) == .success([]))
        #expect(await transport.sentFrames.count == 2)
    }
    
    @Test func listWithWrongPageEchoThrowsMalformedResponse() async throws {
        let wrongEcho: FakeTransport.Responder = { frame in
            let body = Self.payload(of: frame)
            if body.first == 0x01 {
                return Self.reply(to: frame, raw: FakeTransport.initReplyPayload)
            }
            return Self.reply(to: frame, raw: FileVectors.listPayload(page: 1, entries: FileVectors.entry001))
        }
        let transport = FakeTransport(responder: wrongEcho)
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        let result = await attemptList(client)
        #expect(result == .failure(.malformedResponse(reason: "list page 1, expected 0")))
    }
    
    @Test func listPageRejectedByDeviceThrowsStatusRejected() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        let rejecting: FakeTransport.Responder = { frame in
            Self.reply(to: frame, status: 1, raw: Array("invalid id".utf8))
        }
        await transport.setResponder(rejecting)
        let result = await attemptList(client)
        #expect(result == .failure(.statusRejected(status: 1, reason: "invalid id")))
    }
    
    @Test func cancelledListStopsBeforeNextPage() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        let task = Task { await attemptList(client) }
        await transport.waitForSent(count: 1)
        task.cancel()
        let sent = try #require(await transport.sentFrames.first)
        await transport.reply(Self.reply(to: sent, raw: FileVectors.listPayload(page: 0, entries: FileVectors.entry001)))
        #expect(await task.value == .failure(.cancelled))
        #expect(await transport.sentFrames.count == 1)
    }
    
    // MARK: - STAT
    
    @Test func statReturnsParsedNode() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        #expect(await attemptStat(client, fid: 56) == .success(FileVectors.stat56))
        let sent = try #require(await transport.sentFrames.last)
        #expect(Self.payload(of: sent) == FileVectors.statRequest56)
    }
    
    @Test func statRejectedThrowsStatusRejected() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        let rejecting: FakeTransport.Responder = { frame in
            Self.reply(to: frame, status: 1, raw: Array("invalid id".utf8))
        }
        await transport.setResponder(rejecting)
        let result = await attemptStat(client, fid: 56)
        #expect(result == .failure(.statusRejected(status: 1, reason: "invalid id")))
    }
    
    @Test func statWithShortPayloadThrowsMalformedResponse() async throws {
        let transport = FakeTransport(responder: Self.device(statPayload: [0x01, 0x02, 0x03]))
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        let result = await attemptStat(client, fid: 56)
        #expect(result == .failure(.malformedResponse(reason: "stat payload has 3 bytes")))
    }
    
    // MARK: - Idle re-INIT
    
    @Test func commandAfterIdleSendsInitFirst() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(idleReinit: .zero))
        try await client.connect()
        #expect(await attemptStat(client, fid: 56) == .success(FileVectors.stat56))
        let sent = await transport.sentFrames.dropFirst().map(Self.payload(of:))
        #expect(sent == [FileVectors.initRequest, FileVectors.statRequest56])
    }
    
    @Test func commandWithinIdleWindowSendsNoExtraInit() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        _ = await attemptStat(client, fid: 56)
        _ = await attemptStat(client, fid: 56)
        let sent = await transport.sentFrames.map(Self.payload(of:))
        #expect(sent == [FileVectors.initRequest, FileVectors.statRequest56, FileVectors.statRequest56])
    }
    
    @Test func idleReinitHonorsThreshold() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(idleReinit: .milliseconds(300)))
        try await client.connect()
        _ = await attemptStat(client, fid: 56)
        try await Task.sleep(for: .milliseconds(100))
        _ = await attemptStat(client, fid: 56)
        try await Task.sleep(for: .milliseconds(600))
        _ = await attemptStat(client, fid: 56)
        let sent = await transport.sentFrames.map(Self.payload(of:))
        let stat = FileVectors.statRequest56
        #expect(sent == [FileVectors.initRequest, stat, stat, FileVectors.initRequest, stat])
    }
    
    @Test func idleReinitRefreshesChunkSize() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(idleReinit: .zero))
        try await client.connect()
        await transport.setResponder(Self.device(chunk: [0x00, 0x00, 0x00, 0x04, 0x00]))
        _ = await attemptStat(client, fid: 56)
        #expect(await client.chunkSize == 1024)
    }
    
    @Test func rejectedIdleReinitSkipsCommandAndNextCommandRetriesInit() async throws {
        let transport = FakeTransport(responder: Self.device())
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(idleReinit: .zero))
        try await client.connect()
        let rejecting: FakeTransport.Responder = { frame in
            Self.reply(to: frame, status: 1, raw: Array("busy".utf8))
        }
        await transport.setResponder(rejecting)
        #expect(await attemptStat(client, fid: 56) == .failure(.statusRejected(status: 1, reason: "busy")))
        #expect(await transport.sentFrames.dropFirst().map(Self.payload(of:)) == [FileVectors.initRequest])
        await transport.setResponder(Self.device())
        #expect(await attemptStat(client, fid: 56) == .success(FileVectors.stat56))
        let sent = await transport.sentFrames.dropFirst().map(Self.payload(of:))
        #expect(sent == [FileVectors.initRequest, FileVectors.initRequest, FileVectors.statRequest56])
    }
    
    @Test func multiPageListWithIdleReinitCompletesWithoutDeadlock() async throws {
        let pages = [FileVectors.entry001, FileVectors.entryTest, FileVectors.entry001]
        let transport = FakeTransport(responder: Self.device(pages: pages))
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration(idleReinit: .zero))
        try await client.connect()
        let clock = ContinuousClock()
        let start = clock.now
        let result = await attemptList(client)
        #expect(result == .success([FileVectors.node001, FileVectors.nodeTest, FileVectors.node001]))
        #expect(clock.now - start < .seconds(2))
    }
    
    // MARK: - Serialization
    
    @Test func statWaitsForAllListPages() async throws {
        let transport = FakeTransport(autoReplyInit: true)
        let client = FileClient(transport: transport, product: .ep133, configuration: configuration())
        try await client.connect()
        let list = Task { await attemptList(client) }
        await transport.waitForSent(count: 1)
        let stat = Task { await attemptStat(client, fid: 56) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.sentFrames.count == 1)
        var sent = try #require(await transport.sentFrames.first)
        await transport.reply(Self.reply(to: sent, raw: FileVectors.listPayload(page: 0, entries: FileVectors.entry001)))
        await transport.waitForSent(count: 2)
        #expect(await transport.sentFrames.count == 2)
        sent = try #require(await transport.sentFrames.last)
        #expect(Self.payload(of: sent) == [0x04, 0x00, 0x01, 0x03, 0xE8])
        await transport.reply(Self.reply(to: sent, raw: FileVectors.listPayload(page: 1, entries: [])))
        await transport.waitForSent(count: 3)
        sent = try #require(await transport.sentFrames.last)
        #expect(Self.payload(of: sent) == FileVectors.statRequest56)
        await transport.reply(Self.reply(to: sent, raw: FileVectors.statPayload56))
        #expect(await list.value == .success([FileVectors.node001]))
        #expect(await stat.value == .success(FileVectors.stat56))
    }
}
