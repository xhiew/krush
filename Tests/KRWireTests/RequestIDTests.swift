import Testing
@testable import KRWire

struct RequestIDTests {
    @Test(arguments: [
        (UInt16(0x345), UInt8(0x06), UInt8(0x45)),
        (UInt16(0x0FFF), UInt8(0x1F), UInt8(0x7F)),
        (UInt16(0x0000), UInt8(0x00), UInt8(0x00)),
    ])
    func splitsIntoHighAndLow(raw: UInt16, high5: UInt8, low7: UInt8) {
        let id = RequestID(raw)
        #expect(id.high5 == high5)
        #expect(id.low7 == low7)
    }
    
    @Test func masksTo12Bits() {
        #expect(RequestID(0x1345).value == 0x345)
    }
    
    @Test func defaultStartsAt0x300() {
        var generator = RequestIDGenerator()
        #expect(generator.next().value == 0x300)
        #expect(generator.next().value == 0x301)
        #expect(generator.next().value == 0x302)
    }
    
    @Test func wrapsToZeroAfter0xFFF() {
        var generator = RequestIDGenerator(start: 0x0FFE)
        let values = (0..<4).map { _ in generator.next().value }
        #expect(values == [0x0FFE, 0x0FFF, 0x0000, 0x0001])
    }
    
    @Test func returnsToStartAfter4096Calls() {
        var generator = RequestIDGenerator()
        let first = generator.next()
        for _ in 1..<4096 {
            _ = generator.next()
        }
        #expect(generator.next() == first)
    }
}
