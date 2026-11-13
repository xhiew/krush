//
//  FileCodecTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
import KRCore
import KRWire
@testable import KRFile

struct FileCodecTests {
    private let fourMiB: UInt32 = 4 * 1024 * 1024
    
    // MARK: - Requests
    
    @Test func initRequestBytes() {
        #expect(FileCodec.initRequest(flags: 0x01, maxResponseLength: fourMiB) == FileVectors.initRequest)
        #expect(FileCodec.initRequest(flags: 0x00, maxResponseLength: fourMiB) == FileVectors.initRequestRead)
    }
    
    @Test func listRequestBytes() {
        #expect(FileCodec.listRequest(page: 0, node: 1000) == FileVectors.listRequestSounds)
        #expect(FileCodec.listRequest(page: 0x0102, node: 2000) == FileVectors.listRequestPage258)
    }
    
    @Test func statRequestBytes() {
        #expect(FileCodec.statRequest(fid: 56) == FileVectors.statRequest56)
        #expect(FileCodec.statRequest(fid: 1000) == FileVectors.statRequest1000)
    }
    
    @Test func fullFramesMatchReferenceBytes() {
        let frames = [
            SysExFrame.fileRequest(product: .ep133, id: RequestID(0x300), payload: FileVectors.initRequest),
            SysExFrame.fileRequest(product: .ep133, id: RequestID(0x301), payload: FileVectors.listRequestSounds),
            SysExFrame.fileRequest(product: .ep133, id: RequestID(0x302), payload: FileVectors.statRequest56)
        ]
        #expect(frames == [FileVectors.initFrame, FileVectors.listFrame, FileVectors.statFrame])
    }
    
    // MARK: - chunkSize
    
    @Test func chunkSizeReadsBigEndianLength() {
        #expect(FileCodec.chunkSize(initResponse: [0x00, 0x00, 0x00, 0x02, 0x00]) == 512)
        #expect(FileCodec.chunkSize(initResponse: [0x00, 0x00, 0x00, 0x04, 0x00]) == 1024)
    }
    
    @Test func chunkSizeIsClampedToUpperBound() {
        #expect(FileCodec.chunkSize(initResponse: [0x00, 0x01, 0x00, 0x00, 0x00]) == FileCodec.maxChunkSize)
        #expect(FileCodec.chunkSize(initResponse: [0x00, 0x00, 0xFF, 0xFF, 0x00]) == FileCodec.maxChunkSize)
        #expect(FileCodec.chunkSize(initResponse: [0xFF, 0xFF, 0xFF, 0xFF, 0x00]) == FileCodec.maxChunkSize)
        #expect(FileCodec.chunkSize(initResponse: [0x00, 0x00, 0x00, 0x80, 0x00]) == 32_768)
    }
    
    @Test func maxChunkFitsInOneAssembledFrame() {
        let assemblerFrameLimit = 65_536
        let pageHeader = [UInt8](repeating: 0, count: 16)
        let payload = pageHeader + [UInt8](repeating: 0xFF, count: FileCodec.maxChunkSize)
        let frame = SysExFrame.fileRequest(product: .ep133, id: RequestID(0x300), payload: payload)
        #expect(frame.count <= assemblerFrameLimit)
    }
    
    @Test func chunkSizeFallsBackTo512() {
        #expect(FileCodec.chunkSize(initResponse: [0x00, 0x00, 0x00, 0x00, 0x00]) == 512)
        #expect(FileCodec.chunkSize(initResponse: [0x00, 0x00, 0x02]) == 512)
        #expect(FileCodec.chunkSize(initResponse: []) == 512)
    }
    
    // MARK: - stat
    
    @Test func statParsesReferencePayloads() throws {
        #expect(try FileCodec.stat(FileVectors.statPayload56) == FileVectors.stat56)
        #expect(try FileCodec.stat(FileVectors.statPayload999) == FileVectors.stat999)
    }
    
    @Test func statWithoutNameHasEmptyName() throws {
        let stat = try FileCodec.stat(Array(FileVectors.statPayload56.prefix(9)))
        #expect(stat.name == "")
        #expect(stat.fid == 56)
    }
    
    @Test func statNameWithoutTerminatorRunsToEnd() throws {
        let stat = try FileCodec.stat(Array(FileVectors.statPayload56.dropLast()))
        #expect(stat.name == "056.pcm")
    }
    
    @Test func statRejectsShortPayload() {
        #expect(throws: KRError.malformedResponse(reason: "stat payload has 3 bytes")) {
            try FileCodec.stat([0x01, 0x02, 0x03])
        }
    }
    
    @Test func statResponseFrameCrossChecksTestFrames() throws {
        guard case .response(let response) = try SysExFrame.parse(FileVectors.statResponseFrame) else {
            Issue.record("expected a response frame")
            return
        }
        #expect(response.id == RequestID(0x302))
        #expect(try FileCodec.stat(response.payload) == FileVectors.stat56)
        let built = TestFrames.response(id: 0x302, raw: FileVectors.statPayload56)
        #expect(built == FileVectors.statResponseFrame)
    }
    
    // MARK: - listPage
    
    @Test func listPageParsesEntries() throws {
        let payload = FileVectors.listPayload(page: 0, entries: FileVectors.entry001 + FileVectors.entryTest)
        #expect(try FileCodec.listPage(payload, expectedPage: 0) == [FileVectors.node001, FileVectors.nodeTest])
    }
    
    @Test func listPageEndsOnEchoOnlyOrEmpty() throws {
        #expect(try FileCodec.listPage([0x00, 0x00], expectedPage: 0) == nil)
        #expect(try FileCodec.listPage([], expectedPage: 0) == nil)
    }
    
    @Test func listPageRejectsWrongEcho() {
        let payload = FileVectors.listPayload(page: 1, entries: FileVectors.entry001)
        #expect(throws: KRError.malformedResponse(reason: "list page 1, expected 0")) {
            try FileCodec.listPage(payload, expectedPage: 0)
        }
    }
    
    @Test func listPageIgnoresTruncatedEntry() throws {
        let payload = FileVectors.listPayload(page: 0, entries: [0x00, 0x01, 0x1D, 0x00, 0x00])
        #expect(try FileCodec.listPage(payload, expectedPage: 0) == [])
    }
    
    @Test func listPageLastNameWithoutTerminatorRunsToEnd() throws {
        let payload = FileVectors.listPayload(page: 0, entries: Array(FileVectors.entryTest.dropLast()))
        #expect(try FileCodec.listPage(payload, expectedPage: 0) == [FileVectors.nodeTest])
    }
}
