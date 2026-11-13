import KRCore
import Testing
@testable import KRWire

struct RequestVector: Sendable, CustomTestStringConvertible {
    let name: String
    let product: Product
    let id: UInt16
    let payload: [UInt8]
    let frame: [UInt8]
    
    var testDescription: String { name }
}

struct MalformedVector: Sendable, CustomTestStringConvertible {
    let name: String
    let frame: [UInt8]
    /// `nil` means the frame parses (to `.unrelated`) without throwing.
    let error: KRError?
    
    var testDescription: String { name }
}

enum FrameFixtures {
    // MARK: Requests (hand computed)
    
    static let requestVectors: [RequestVector] = [
        // ko2-io src/sysex.rs:150 (STAT-like): id 0x345 -> byte6 0x66, byte7 0x45.
        RequestVector(
            name: "STAT EP-133 id 0x345",
            product: .ep133,
            id: 0x345,
            payload: [0x0B, 0x01, 0x02],
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x45, 0x05, 0x00, 0x0B, 0x01, 0x02, 0xF7]
        ),
        // ep-series-sysex docs/file-protocol.md:120 (FILE_INIT write).
        RequestVector(
            name: "INIT write id 0x300",
            product: .ep133,
            id: 0x300,
            payload: [0x01, 0x01, 0x00, 0x40, 0x00, 0x00],
            frame: [
                0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x00, 0x05,
                0x00, 0x01, 0x01, 0x00, 0x40, 0x00, 0x00, 0xF7,
            ]
        ),
        // EP-40, fid 1000 = 03 E8 -> packed flag 04 (0xE8 high bit is 3rd byte).
        RequestVector(
            name: "STAT EP-40 id 0xFFF fid 1000",
            product: .ep40,
            id: 0xFFF,
            payload: [0x0B, 0x03, 0xE8],
            frame: [0xF0, 0x00, 0x20, 0x76, 0x3C, 0x40, 0x7F, 0x7F, 0x05, 0x04, 0x0B, 0x03, 0x68, 0xF7]
        ),
    ]
    
    static let emptyRequestFrame: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x45, 0x05, 0xF7]
    
    // MARK: Responses
    
    /// Minimal successful response, length 11: byte6 = 0x20 | hi5(0x345) = 0x26.
    static let emptyResponseFrame: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x26, 0x45, 0x05, 0x00, 0xF7]
    
    /// Raw payload with a byte >= 0x80, ep-series-sysex docs/sysex-protocol.md:61-69.
    static let highBytePayload: [UInt8] = [0x07, 0xD0, 0x00, 0x2C]
    
    /// Success response: status 00 stays outside packed7 (`02 07 50 00 2C`).
    static let highBytePayloadResponseFrame: [UInt8] = [
        0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x26, 0x45, 0x05,
        0x00, 0x02, 0x07, 0x50, 0x00, 0x2C, 0xF7,
    ]
    
    /// "invalid id", ep-series-sysex docs/sysex-protocol.md:89-91.
    static let rejectReasonRaw: [UInt8] = Array("invalid id".utf8)
    
    /// Hand-packed "invalid id": group of 7, then group of 3, all flags 0.
    static let rejectReasonPacked: [UInt8] = [
        0x00, 0x69, 0x6E, 0x76, 0x61, 0x6C, 0x69, 0x64,
        0x00, 0x20, 0x69, 0x64,
    ]
    
    static let rejectFrame: [UInt8] = rejectionFrame(status: 0x01, packedReason: rejectReasonPacked)
    
    static let rejectFrameWithPadding: [UInt8] = rejectionFrame(
        status: 0x01,
        packedReason: Packed7.encode(rejectReasonRaw + [0x00, 0x20, 0x00])
    )
    
    static let rejectEmptyFrame: [UInt8] = rejectionFrame(status: 0x01, packedReason: [])
    
    private static func rejectionFrame(status: UInt8, packedReason: [UInt8]) -> [UInt8] {
        [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x26, 0x45, 0x05, status] + packedReason + [0xF7]
    }
    
    // MARK: Debug frames
    
    /// ep-series-sysex tests/test_roundtrip.py:590-593, wrapped in F0/F7.
    static let ep133DebugFrame: [UInt8] =
        [0xF0, 0x00, 0x20, 0x76, 0x33, 0x33] + Array("err pattern 71 2_5_1".utf8) + [0xF7]
    static let ep40DebugFrame: [UInt8] =
        [0xF0, 0x00, 0x20, 0x76, 0x3C, 0x33] + Array("err pattern 213 2_5_1".utf8) + [0xF7]
    static let ep40DebugFrameWithTrailer: [UInt8] =
        [0xF0, 0x00, 0x20, 0x76, 0x3C, 0x33] + Array("err pattern 213 2_5_1".utf8) + [0x0D, 0x0A, 0x00, 0xF7]
    /// test_roundtrip.py:590-593 normal frames (flags 0x20, request id 0).
    static let ep133NormalFrame: [UInt8] =
        [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x20, 0x00, 0x05, 0x00, 0xF7]
    static let ep40NormalFrame: [UInt8] =
        [0xF0, 0x00, 0x20, 0x76, 0x3C, 0x40, 0x20, 0x00, 0x05, 0x00, 0xF7]
    static let minimalDebugFrame: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x3C, 0x33, 0xF7]
    
    // MARK: Malformed and boundary frames
    
    static let malformedVectors: [MalformedVector] = [
        MalformedVector(name: "empty", frame: [], error: .frameMissingDelimiters),
        MalformedVector(name: "F0 F7", frame: [0xF0, 0xF7], error: nil),
        MalformedVector(
            name: "missing F0",
            frame: [0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x45, 0x05, 0xF7],
            error: .frameMissingDelimiters
        ),
        MalformedVector(
            name: "missing F7",
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x45, 0x05],
            error: .frameMissingDelimiters
        ),
        MalformedVector(
            name: "length 6 no marker",
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0xF7],
            error: .frameTooShort(length: 6)
        ),
        MalformedVector(
            name: "request length 9",
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x45, 0xF7],
            error: .frameTooShort(length: 9)
        ),
        MalformedVector(
            name: "response length 10",
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x26, 0x45, 0x05, 0xF7],
            error: .frameTooShort(length: 10)
        ),
        MalformedVector(
            name: "0x80 in TE body",
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x26, 0x45, 0x05, 0x00, 0x80, 0xF7],
            error: .invalidDataByte(offset: 10, value: 0x80)
        ),
        MalformedVector(
            name: "unfiltered realtime 0xF8",
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x66, 0x45, 0x05, 0xF8, 0xF7],
            error: .invalidDataByte(offset: 9, value: 0xF8)
        ),
        MalformedVector(
            name: "unknown marker",
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0x41, 0x66, 0x45, 0x05, 0x00, 0xF7],
            error: nil
        ),
        MalformedVector(
            name: "flags without 0x20",
            frame: [0xF0, 0x00, 0x20, 0x76, 0x33, 0x40, 0x06, 0x45, 0x05, 0x00, 0xF7],
            error: nil
        ),
        // MIDI Identity reply embedding the TE manufacturer id later on.
        MalformedVector(
            name: "Identity reply",
            frame: [0xF0, 0x7E, 0x7F, 0x06, 0x02, 0x00, 0x20, 0x76, 0x33, 0x00, 0xF7],
            error: nil
        ),
        MalformedVector(name: "non-TE with high byte", frame: [0xF0, 0x43, 0x10, 0x80, 0xF7], error: nil),
    ]
}
