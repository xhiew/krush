//
//  FileTransferCodecTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Testing
import KRCore
@testable import KRFile

struct FileTransferCodecTests {
    private func putOpen(
        name: String = "056.pcm",
        maxPayload: Int = 433
    ) throws(KRError) -> [UInt8] {
        try FileCodec.putOpenRequest(
            flags: .sound, fid: 56, parent: 1000, size: 1234, name: name, maxPayload: maxPayload
        )
    }
    
    private func isInvalid(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch let KRError.invalidArgument(reason) {
            return !reason.isEmpty
        } catch {
            return false
        }
    }
    
    private func isMalformed(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch let KRError.malformedResponse(reason) {
            return !reason.isEmpty
        } catch {
            return false
        }
    }
    
    // MARK: - Requests
    
    @Test func simpleRequestBytes() {
        #expect(FileCodec.getOpenRequest(fid: 56) == FileVectors.getOpenRequest56)
        #expect(FileCodec.getDataRequest(page: 0x0102) == FileVectors.getDataRequest258)
        #expect(FileCodec.putDataRequest(page: 3, bytes: []) == FileVectors.putEofPage3)
        #expect(FileCodec.deleteRequest(fid: 56) == FileVectors.deleteRequest56)
        #expect(FileCodec.playRequest(fid: 1) == FileVectors.playRequest1)
    }
    
    @Test func putDataRequestAppendsBytes() {
        #expect(FileCodec.putDataRequest(page: 1, bytes: [0xAA, 0xBB]) == [0x02, 0x01, 0x00, 0x01, 0xAA, 0xBB])
    }
    
    @Test func putOpenRequestBytes() throws {
        #expect(try putOpen() == FileVectors.putOpenSound)
        let project = try FileCodec.putOpenRequest(
            flags: .projectArchive, fid: 3000, parent: 2000, size: 59_392, name: "01", maxPayload: 433
        )
        #expect(project == FileVectors.putOpenProject)
    }
    
    // MARK: - Sizes
    
    @Test func putPayloadBytesMatchesReference() {
        #expect(FileCodec.putPayloadBytes(chunkSize: 512) == 433)
        #expect(FileCodec.putPayloadBytes(chunkSize: 0) == 433)
        #expect(FileCodec.putPayloadBytes(chunkSize: 17) == 433)
        #expect(FileCodec.putPayloadBytes(chunkSize: 18) == 1)
        #expect(FileCodec.putPayloadBytes(chunkSize: 1024) == 881)
    }
    
    @Test func getPageCountRoundsUp() {
        #expect(FileCodec.getPageCount(size: 0) == 0)
        #expect(FileCodec.getPageCount(size: 1) == 1)
        #expect(FileCodec.getPageCount(size: 324) == 1)
        #expect(FileCodec.getPageCount(size: 325) == 2)
        #expect(FileCodec.getPageCount(size: 46_876) == 145)
    }
    
    // MARK: - Responses
    
    @Test func getOpenParsesHeader() throws {
        let open = try FileCodec.getOpen(FileVectors.getOpenPayload, fid: 56)
        #expect(open.flags == 0x1D)
        #expect(open.size == 1234)
        #expect(open.name == "056")
    }
    
    @Test func getOpenAcceptsEmptyName() throws {
        let open = try FileCodec.getOpen(Array(FileVectors.getOpenPayload.prefix(7)), fid: 56)
        #expect(open.name == "")
    }
    
    @Test func getOpenRejectsShortPayload() {
        #expect(isMalformed { _ = try FileCodec.getOpen(Array(FileVectors.getOpenPayload.prefix(6)), fid: 56) })
    }
    
    @Test func getOpenRejectsFidMismatch() {
        #expect(isMalformed { _ = try FileCodec.getOpen(FileVectors.getOpenPayload, fid: 57) })
    }
    
    @Test func getDataPageReturnsData() throws {
        #expect(Array(try FileCodec.getDataPage([0x00, 0x01, 0xAA, 0xBB], expectedPage: 1)) == [0xAA, 0xBB])
        #expect(try FileCodec.getDataPage([0x00, 0x01], expectedPage: 1).isEmpty)
    }
    
    @Test func getDataPageRejectsBadPayloads() {
        #expect(isMalformed { _ = try FileCodec.getDataPage([0x00], expectedPage: 1) })
        #expect(isMalformed { _ = try FileCodec.getDataPage([0x00, 0x02, 0xAA], expectedPage: 1) })
    }
    
    @Test func putOpenEchoChecks() throws {
        try FileCodec.checkPutOpenEcho([], fid: 56)
        try FileCodec.checkPutOpenEcho([0x00], fid: 56)
        try FileCodec.checkPutOpenEcho([0x00, 0x38], fid: 56)
        #expect(isMalformed { try FileCodec.checkPutOpenEcho([0x00, 0x39], fid: 56) })
    }
    
    // MARK: - Validation
    
    @Test func putOpenRejectsBadNames() {
        #expect(isInvalid { _ = try putOpen(name: "é") })
        #expect(isInvalid { _ = try putOpen(name: "a\0b") })
        #expect(isInvalid { _ = try putOpen(name: "") })
    }
    
    @Test func putOpenRejectsOversizedPayload() {
        #expect(isInvalid { _ = try putOpen(name: String(repeating: "a", count: 430)) })
    }

    // 11 header bytes + name + NUL must fit in 433.
    @Test func putOpenAcceptsANameExactlyAtTheLimit() throws {
        #expect(try putOpen(name: String(repeating: "a", count: 421)).count == 433)
        #expect(isInvalid { _ = try putOpen(name: String(repeating: "a", count: 422)) })
    }
}
