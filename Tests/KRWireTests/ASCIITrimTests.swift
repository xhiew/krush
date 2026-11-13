import Testing
@testable import KRWire

struct ASCIITrimTests {
    struct Case: Sendable {
        let bytes: [UInt8]
        let expected: String
    }
    
    static let reasonCases: [Case] = {
        let reason = Array("invalid id".utf8)
        let padded: [UInt8] = [0x00, 0x20] + reason + [0x00, 0x00, 0x20]
        let newline: [UInt8] = [0x0A, 0x78, 0x0D]
        return [
            Case(bytes: [], expected: ""),
            Case(bytes: [0x00], expected: ""),
            Case(bytes: [0x20, 0x00, 0x20], expected: ""),
            Case(bytes: Array("abc".utf8), expected: "abc"),
            Case(bytes: padded, expected: "invalid id"),
            Case(bytes: Array("a b".utf8), expected: "a b"),
            Case(bytes: [0x61, 0x00, 0x62], expected: "a\0b"),
            // tab/CR/LF are not trimmed for the reason set
            Case(bytes: newline, expected: "\nx\r")
        ]
    }()
    
    static let debugCases: [Case] = {
        let crlf: [UInt8] = [0x0D, 0x0A] + Array("err".utf8) + [0x0D, 0x0A, 0x00]
        return [
            Case(bytes: [], expected: ""),
            Case(bytes: [0x09, 0x0A, 0x0D, 0x20, 0x00], expected: ""),
            Case(bytes: crlf, expected: "err"),
            Case(bytes: Array("a\nb".utf8), expected: "a\nb")
        ]
    }()
    
    @Test(arguments: reasonCases)
    func reasonSetTrimsOnlyNULAndSpace(testCase: Case) {
        #expect(ASCIITrim.string(testCase.bytes, set: ASCIITrim.reasonSet) == testCase.expected)
    }
    
    @Test(arguments: debugCases)
    func debugSetTrimsWhitespaceAndNUL(testCase: Case) {
        #expect(ASCIITrim.string(testCase.bytes, set: ASCIITrim.debugSet) == testCase.expected)
    }
    
    @Test func trimWorksOnSliceWithNonZeroStartIndex() {
        let bytes: [UInt8] = [0x41, 0x20, 0x42, 0x20, 0x43]
        let trimmed = ASCIITrim.trim(bytes[1...3], set: ASCIITrim.reasonSet)
        #expect(Array(trimmed) == [0x42])
    }
    
    @Test func emptyAfterTrimIsEmptySlice() {
        let bytes: [UInt8] = [0x20, 0x20]
        #expect(ASCIITrim.trim(bytes[...], set: ASCIITrim.reasonSet).isEmpty)
    }
}
