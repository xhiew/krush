/// DELETE is the bare `06` + fid, never `06 02`. MOVE (`0x0C`) is left out: unverified.
public struct FileOpcode: Hashable, Sendable {
    public let bytes: [UInt8]
    
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
    
    public static let initialize = FileOpcode(bytes: [0x01])
    public static let putOpen = FileOpcode(bytes: [0x02, 0x00])
    public static let putData = FileOpcode(bytes: [0x02, 0x01])
    public static let getOpen = FileOpcode(bytes: [0x03, 0x00])
    public static let getData = FileOpcode(bytes: [0x03, 0x01])
    public static let list = FileOpcode(bytes: [0x04])
    public static let play = FileOpcode(bytes: [0x05, 0x01])
    public static let delete = FileOpcode(bytes: [0x06])
    public static let metadataSet = FileOpcode(bytes: [0x07, 0x01])
    public static let metadataGet = FileOpcode(bytes: [0x07, 0x02])
    public static let stat = FileOpcode(bytes: [0x0B])
}
