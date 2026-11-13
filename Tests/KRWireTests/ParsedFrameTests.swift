//
//  ParsedFrameTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore
import Testing
@testable import KRWire

struct ParsedFrameTests {
    @Test func fileRequestEqualityDistinguishesEveryField() {
        let base = FileRequest(product: .ep133, id: RequestID(0x345), command: 0x05, payload: [1, 2])
        #expect(base == FileRequest(product: .ep133, id: RequestID(0x345), command: 0x05, payload: [1, 2]))
        #expect(base != FileRequest(product: .ep40, id: RequestID(0x345), command: 0x05, payload: [1, 2]))
        #expect(base != FileRequest(product: .ep133, id: RequestID(0x346), command: 0x05, payload: [1, 2]))
        #expect(base != FileRequest(product: .ep133, id: RequestID(0x345), command: 0x01, payload: [1, 2]))
        #expect(base != FileRequest(product: .ep133, id: RequestID(0x345), command: 0x05, payload: [1]))
    }
    
    @Test func fileResponseEqualityDistinguishesEveryField() {
        let base = FileResponse(product: .ep133, id: RequestID(0x345), command: 0x05, status: 0, payload: [1])
        #expect(base == FileResponse(product: .ep133, id: RequestID(0x345), command: 0x05, status: 0, payload: [1]))
        #expect(base != FileResponse(product: .ep40, id: RequestID(0x345), command: 0x05, status: 0, payload: [1]))
        #expect(base != FileResponse(product: .ep133, id: RequestID(0x346), command: 0x05, status: 0, payload: [1]))
        #expect(base != FileResponse(product: .ep133, id: RequestID(0x345), command: 0x01, status: 0, payload: [1]))
        #expect(base != FileResponse(product: .ep133, id: RequestID(0x345), command: 0x05, status: 1, payload: [1]))
        #expect(base != FileResponse(product: .ep133, id: RequestID(0x345), command: 0x05, status: 0, payload: [2]))
    }
    
    @Test func parsedFrameCasesAreDistinct() {
        let request = FileRequest(product: .ep133, id: RequestID(1), command: 5, payload: [])
        let response = FileResponse(product: .ep133, id: RequestID(1), command: 5, status: 0, payload: [])
        let debug = DebugFrame(product: .ep133, text: "x")
        #expect(ParsedFrame.request(request) != .response(response))
        #expect(ParsedFrame.debug(debug) != .unrelated)
        #expect(ParsedFrame.debug(debug) != .debug(DebugFrame(product: .ep40, text: "x")))
        #expect(ParsedFrame.debug(debug) != .debug(DebugFrame(product: .ep133, text: "y")))
        #expect(ParsedFrame.unrelated == .unrelated)
    }
    
    @Test func nonZeroStatusIsNotSuccess() {
        let response = FileResponse(product: .ep133, id: RequestID(1), command: 5, status: 0x7F, payload: [])
        #expect(!response.isSuccess)
        #expect(response.reason == "")
    }
    
    @Test func successIgnoresPayloadForReason() {
        let response = FileResponse(product: .ep133, id: RequestID(1), command: 5, status: 0, payload: Array("hi".utf8))
        #expect(response.reason == nil)
    }
    
    @Test func parsesEP40ResponseWithProductAndRejectReason() throws {
        let body = Packed7.encode(Array("no".utf8))
        let frame: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x3C, 0x40, 0x3F, 0x7F, 0x05, 0x02] + body + [0xF7]
        let parsed = try SysExFrame.parse(frame)
        guard case .response(let response) = parsed else {
            Issue.record("expected response")
            return
        }
        #expect(response.product == .ep40)
        #expect(response.id == RequestID(0xFFF))
        #expect(response.status == 2)
        #expect(response.reason == "no")
    }
    
    @Test func goodMatchOnlyWhenIDAndCommandAgree() {
        let response = FileResponse(product: .ep133, id: RequestID(0x300), command: 0x01, status: 0, payload: [])
        #expect(response.matches(RequestID(0x300), command: .greet))
        #expect(!response.matches(RequestID(0x300), command: .file))
    }
}
