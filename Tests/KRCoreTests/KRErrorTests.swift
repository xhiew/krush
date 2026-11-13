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
    }
    
    @Test(arguments: [
        KRError.frameMissingDelimiters,
        .frameTooShort(length: 6),
        .invalidDataByte(offset: 2, value: 0x80),
        .statusRejected(status: 1, reason: "invalid id"),
        .deviceDebugFrame(text: "err")
    ])
    func descriptionIsNotEmpty(error: KRError) {
        #expect(!error.description.isEmpty)
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
    }
}
