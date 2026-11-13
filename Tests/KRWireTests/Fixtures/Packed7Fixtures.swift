import Testing

struct Packed7Vector: Sendable, CustomTestStringConvertible {
    let name: String
    let raw: [UInt8]
    let encoded: [UInt8]
    
    var testDescription: String { name }
}

enum Packed7Fixtures {
    static let knownVectors: [Packed7Vector] = [
        // ep-series-sysex docs/sysex-protocol.md:61-69
        Packed7Vector(name: "doc example", raw: [0x07, 0xD0, 0x00, 0x2C], encoded: [0x02, 0x07, 0x50, 0x00, 0x2C]),
        Packed7Vector(name: "empty", raw: [], encoded: []),
        Packed7Vector(name: "00", raw: [0x00], encoded: [0x00, 0x00]),
        Packed7Vector(name: "7F", raw: [0x7F], encoded: [0x00, 0x7F]),
        Packed7Vector(name: "80", raw: [0x80], encoded: [0x01, 0x00]),
        // ep-series-sysex tests/test_roundtrip.py:71 (8 encoded bytes)
        Packed7Vector(
            name: "FF x7",
            raw: [UInt8](repeating: 0xFF, count: 7),
            encoded: [0x7F] + [UInt8](repeating: 0x7F, count: 7)
        ),
        // Hand computed from the same rules: second group is one byte.
        Packed7Vector(
            name: "FF x8",
            raw: [UInt8](repeating: 0xFF, count: 8),
            encoded: [0x7F] + [UInt8](repeating: 0x7F, count: 7) + [0x01, 0x7F]
        )
    ]
    
    /// Raw inputs of ep-series-sysex tests/test_roundtrip.py:55-64.
    static let roundTripRaws: [[UInt8]] = [
        [],
        [0x00],
        [0x7F],
        [0x80],
        [UInt8](repeating: 0xFF, count: 7),
        [UInt8](repeating: 0xFF, count: 8),
        (0...255).map { UInt8($0) }
    ]
    
    /// Lengths from the plan; 324 = GET page, 433 = PUT page, 1000 = ko2-io src/sysex.rs:141.
    static let randomLengths: [Int] = [1, 2, 6, 7, 8, 13, 14, 15, 100, 324, 433, 1000]
}
