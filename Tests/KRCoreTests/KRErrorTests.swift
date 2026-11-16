//
//  KRErrorTests.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import Testing
@testable import KRCore

struct KRErrorTests {
    @Test func equatableDistinguishesAssociatedValues() {
        #expect(KRError.frameTooShort(length: 6) == .frameTooShort(length: 6))
        #expect(KRError.frameTooShort(length: 6) != .frameTooShort(length: 9))
        #expect(KRError.invalidDataByte(offset: 2, value: 0x80) != .invalidDataByte(offset: 3, value: 0x80))
        #expect(KRError.invalidDataByte(offset: 2, value: 0x80) != .invalidDataByte(offset: 2, value: 0xF8))
        #expect(KRError.statusRejected(status: 1, reason: "a") != .statusRejected(status: 2, reason: "a"))
        #expect(KRError.statusRejected(status: 1, reason: "a") != .statusRejected(status: 1, reason: "b"))
        #expect(KRError.deviceDebugFrame(text: "x") != .deviceDebugFrame(text: "y"))
        #expect(KRError.frameMissingDelimiters != .frameTooShort(length: 0))
        #expect(KRError.timeout(requestID: 0x300) == .timeout(requestID: 0x300))
        #expect(KRError.timeout(requestID: 0x300) != .timeout(requestID: 0x301))
        #expect(KRError.transportFailure(operation: "a", status: 1) != .transportFailure(operation: "a", status: 2))
        #expect(KRError.transportFailure(operation: "a", status: 1) != .transportFailure(operation: "b", status: 1))
        #expect(KRError.malformedResponse(reason: "a") != .malformedResponse(reason: "b"))
        #expect(KRError.cancelled != .disconnected)
        #expect(KRError.disconnected != .alreadyConnected)
        #expect(KRError.cancelled != .alreadyConnected)
        #expect(KRError.deviceNotFound != .disconnected)
        #expect(KRError.invalidArgument(reason: "a") != .invalidArgument(reason: "b"))
        #expect(KRError.transferInterrupted != .cancelled)
    }
    
    @Test(arguments: [
        KRError.frameMissingDelimiters,
        .frameTooShort(length: 6),
        .invalidDataByte(offset: 2, value: 0x80),
        .statusRejected(status: 1, reason: "invalid id"),
        .deviceDebugFrame(text: "err"),
        .timeout(requestID: 0x300),
        .disconnected,
        .alreadyConnected,
        .cancelled,
        .deviceNotFound,
        .transportFailure(operation: "MIDIClientCreateWithBlock", status: -10830),
        .malformedResponse(reason: "short payload"),
        .invalidArgument(reason: "name"),
        .transferInterrupted
    ])
    func descriptionIsNotEmpty(error: KRError) {
        #expect(!error.description.isEmpty)
    }
    
    @Test func transferInterruptedAsksForAPowerCycle() {
        #expect(KRError.transferInterrupted.description.contains("power-cycle"))
    }

    @Test func descriptionsContainAssociatedValues() {
        #expect(KRError.frameTooShort(length: 6).description == "SysEx frame is too short (6 bytes)")
        #expect(KRError.invalidDataByte(offset: 9, value: 0xF8).description
            == "Invalid data byte 0xF8 at offset 9")
        #expect(KRError.invalidDataByte(offset: 1, value: 0x0A).description
            == "Invalid data byte 0x0A at offset 1")
        #expect(KRError.statusRejected(status: 1, reason: "invalid id").description
            == "Device rejected the request with status 0x01: invalid id")
        #expect(KRError.deviceDebugFrame(text: "err pattern").description
            == "Device debug frame: err pattern")
        #expect(KRError.timeout(requestID: 0x300).description == "Request 0x300 timed out")
        #expect(KRError.timeout(requestID: 0x0).description == "Request 0x0 timed out")
        #expect(KRError.disconnected.description == "Transport is not connected")
        #expect(KRError.alreadyConnected.description == "Transport is already connected")
        #expect(KRError.cancelled.description == "Operation was cancelled")
        #expect(KRError.deviceNotFound.description == "No matching device was found")
        #expect(KRError.transportFailure(operation: "MIDISendEventList", status: -50).description
            == "MIDISendEventList failed with status -50")
        #expect(KRError.malformedResponse(reason: "short payload").description
            == "Malformed response: short payload")
        #expect(KRError.invalidArgument(reason: "name").description == "Invalid argument: name")
    }
}
