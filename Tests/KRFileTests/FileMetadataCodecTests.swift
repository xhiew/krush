//
//  FileMetadataCodecTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Testing
import KRCore
@testable import KRFile

struct FileMetadataCodecTests {
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
    
    // MARK: - Requests
    
    @Test func getRequestBytes() throws {
        #expect(try FileCodec.metadataGetRequest(fid: 3100, page: 0, key: "active") == FileVectors.metadataGetActive)
        #expect(try FileCodec.metadataGetRequest(fid: 1, page: 2, key: nil) == FileVectors.metadataGetPage2)
    }
    
    @Test func setRequestBytes() throws {
        let request = try FileCodec.metadataSetRequest(fid: 2000, json: #"{"active":3000}"#, maxPayload: 433)
        #expect(request == FileVectors.metadataSetActive)
    }
    
    // MARK: - Pages
    
    @Test func pageStopsAtNul() throws {
        let payload: [UInt8] = [0x00, 0x00] + Array(#"{"a":1}"#.utf8) + [0x00]
        let page = try #require(try FileCodec.metadataPage(payload, expectedPage: 0))
        #expect(page.text == #"{"a":1}"#)
        #expect(page.isLast)
    }
    
    @Test func pageWithoutTrailingNulIsNotLast() throws {
        let payload: [UInt8] = [0x00, 0x00] + Array("abc".utf8)
        let page = try #require(try FileCodec.metadataPage(payload, expectedPage: 0))
        #expect(page.text == "abc")
        #expect(!page.isLast)
    }
    
    @Test func pageWithEmbeddedNulKeepsFirstText() throws {
        let payload: [UInt8] = [0x00, 0x00, 0x61, 0x62, 0x00, 0x63, 0x64]
        let page = try #require(try FileCodec.metadataPage(payload, expectedPage: 0))
        #expect(page.text == "ab")
        #expect(!page.isLast)
    }
    
    @Test func echoOnlyPageIsTerminator() throws {
        #expect(try FileCodec.metadataPage([0x00, 0x00], expectedPage: 0) == nil)
    }
    
    @Test func pageRejectsWrongEcho() {
        #expect(throws: KRError.self) {
            _ = try FileCodec.metadataPage([0x00, 0x01, 0x61], expectedPage: 0)
        }
    }
    
    // MARK: - Validation
    
    @Test func rejectsInvalidKeyAndJSON() {
        #expect(isInvalid { _ = try FileCodec.metadataGetRequest(fid: 1, page: 0, key: "a\0b") })
        #expect(isInvalid { _ = try FileCodec.metadataSetRequest(fid: 1, json: "", maxPayload: 433) })
        #expect(isInvalid { _ = try FileCodec.metadataSetRequest(fid: 1, json: "{\0}", maxPayload: 433) })
    }
    
    @Test func setRejectsOversizedPayload() {
        let json = "{\"a\":\"" + String(repeating: "x", count: 490) + "\"}"
        #expect(isInvalid { _ = try FileCodec.metadataSetRequest(fid: 1, json: json, maxPayload: 433) })
    }

    // 4 header bytes + JSON + NUL must fit in 433.
    @Test func setAcceptsJSONExactlyAtTheLimit() throws {
        let atLimit = "{\"a\":\"" + String(repeating: "x", count: 428 - 8) + "\"}"
        let overLimit = "{\"a\":\"" + String(repeating: "x", count: 429 - 8) + "\"}"
        #expect(try FileCodec.metadataSetRequest(fid: 1, json: atLimit, maxPayload: 433).count == 433)
        #expect(isInvalid { _ = try FileCodec.metadataSetRequest(fid: 1, json: overLimit, maxPayload: 433) })
    }
}
