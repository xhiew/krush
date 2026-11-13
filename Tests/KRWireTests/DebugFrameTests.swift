import KRCore
import Testing
@testable import KRWire

struct DebugFrameTests {
    @Test func detectsEP133Debug() throws {
        let parsed = try SysExFrame.parse(FrameFixtures.ep133DebugFrame)
        #expect(parsed == .debug(DebugFrame(product: .ep133, text: "err pattern 71 2_5_1")))
    }
    
    @Test func detectsEP40Debug() throws {
        let parsed = try SysExFrame.parse(FrameFixtures.ep40DebugFrame)
        #expect(parsed == .debug(DebugFrame(product: .ep40, text: "err pattern 213 2_5_1")))
    }
    
    @Test(arguments: [FrameFixtures.ep133NormalFrame, FrameFixtures.ep40NormalFrame])
    func doesNotTreatNormalFramesAsDebug(frame: [UInt8]) throws {
        let parsed = try SysExFrame.parse(frame)
        #expect(parsed == .response(FileResponse(
            product: Product(rawValue: frame[SysExFrame.productIndex]),
            id: RequestID(0),
            command: 0x05,
            status: 0,
            payload: []
        )))
    }
    
    @Test func trimsTrailingCRLFAndNUL() throws {
        let parsed = try SysExFrame.parse(FrameFixtures.ep40DebugFrameWithTrailer)
        #expect(parsed == .debug(DebugFrame(product: .ep40, text: "err pattern 213 2_5_1")))
    }
    
    @Test func minimalDebugFrameHasEmptyText() throws {
        let parsed = try SysExFrame.parse(FrameFixtures.minimalDebugFrame)
        #expect(parsed == .debug(DebugFrame(product: .ep40, text: "")))
    }
    
    @Test func unknownProductStillDetectedAsDebug() throws {
        let frame: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x41, 0x33, 0x68, 0x69, 0xF7]
        let parsed = try SysExFrame.parse(frame)
        #expect(parsed == .debug(DebugFrame(product: Product(rawValue: 0x41), text: "hi")))
    }
    
    @Test func errorWrapsText() {
        let debug = DebugFrame(product: .ep133, text: "boom")
        #expect(debug.error == .deviceDebugFrame(text: "boom"))
    }
}
