//
//  FileResponseTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore
import Testing
@testable import KRWire

struct FileResponseTests {
    private struct NotAResponse: Error {}
    
    private func response(_ frame: [UInt8]) throws -> FileResponse {
        guard case .response(let response) = try SysExFrame.parse(frame) else {
            throw NotAResponse()
        }
        return response
    }
    
    @Test func parsesMinimalSuccess() throws {
        let value = try response(FrameFixtures.emptyResponseFrame)
        #expect(value == FileResponse(
            product: .ep133,
            id: RequestID(0x345),
            command: 0x05,
            status: 0,
            payload: []
        ))
        #expect(value.isSuccess)
    }
    
    @Test func recoversHighBytesAndKeepsStatusOutOfPacked7() throws {
        let value = try response(FrameFixtures.highBytePayloadResponseFrame)
        #expect(value.status == 0)
        #expect(value.payload == FrameFixtures.highBytePayload)
    }
    
    @Test func matchesIDAndCommand() throws {
        let value = try response(FrameFixtures.emptyResponseFrame)
        #expect(value.matches(RequestID(0x345), command: .file))
        #expect(!value.matches(RequestID(0x346), command: .file))
        #expect(!value.matches(RequestID(0x345), command: .greet))
    }
    
    @Test func checkPassesOnSuccess() throws {
        let value = try response(FrameFixtures.emptyResponseFrame)
        try value.check()
        #expect(value.reason == nil)
    }
    
    @Test(arguments: [FrameFixtures.rejectFrame, FrameFixtures.rejectFrameWithPadding])
    func rejectionCarriesTrimmedReason(frame: [UInt8]) throws {
        let value = try response(frame)
        #expect(value.status == 1)
        #expect(value.reason == "invalid id")
        #expect(throws: KRError.statusRejected(status: 1, reason: "invalid id")) {
            try value.check()
        }
    }
    
    @Test func rejectionWithEmptyPayloadHasEmptyReason() throws {
        let value = try response(FrameFixtures.rejectEmptyFrame)
        #expect(value.reason == "")
        #expect(throws: KRError.statusRejected(status: 1, reason: "")) {
            try value.check()
        }
    }
    
    @Test func handPackedReasonMatchesEncoder() {
        #expect(Packed7.encode(FrameFixtures.rejectReasonRaw) == FrameFixtures.rejectReasonPacked)
    }
}
