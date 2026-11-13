import KRCore
import Testing
@testable import KRWire

struct ReferenceVectorTests {
    @Test(arguments: ReferenceVectors.pack7Vectors)
    func encodeMatchesReference(vector: ReferencePack7Vector) {
        #expect(Packed7.encode(vector.raw) == vector.encoded)
    }
    
    @Test(arguments: ReferenceVectors.pack7Vectors)
    func decodeOfReferenceReturnsRaw(vector: ReferencePack7Vector) throws {
        #expect(try Packed7.decode(vector.encoded) == vector.raw)
    }
    
    @Test(arguments: ReferenceVectors.requestVectors)
    func frameMatchesReference(vector: ReferenceRequestVector) {
        let frame = SysExFrame.fileRequest(
            product: Product(rawValue: vector.product),
            id: RequestID(vector.id),
            payload: vector.payload
        )
        #expect(frame == [0xF0] + vector.body + [0xF7])
    }
    
    @Test(arguments: ReferenceVectors.requestVectors)
    func parseOfReferenceFrameReturnsRequest(vector: ReferenceRequestVector) throws {
        let parsed = try SysExFrame.parse([0xF0] + vector.body + [0xF7])
        #expect(parsed == .request(FileRequest(
            product: Product(rawValue: vector.product),
            id: RequestID(vector.id),
            command: SysExCommand.file.rawValue,
            payload: vector.payload
        )))
    }
}
