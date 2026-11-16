//
//  SimFileSystem.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

/// Ref: ep-series-sysex `docs/file-protocol.md:66-77`.
public struct SimFileSystem: Sendable {
    public static let directoryFlags: UInt8 = 0x0E
    public static let sampleFlags: UInt8 = 0x1D
    public static let soundsFID: UInt16 = 1000
    public static let projectsFID: UInt16 = 2000
    
    private var nodes: [UInt16: SimNode] = [:]
    
    public init() {
        insert(SimNode(fid: 0, parent: 0, flags: Self.directoryFlags, name: "/"))
        insert(SimNode(fid: Self.soundsFID, parent: 0, flags: Self.directoryFlags, name: "sounds"))
        insert(SimNode(fid: Self.projectsFID, parent: 0, flags: Self.directoryFlags, name: "projects"))
    }
    
    public func node(_ fid: UInt16) -> SimNode? {
        nodes[fid]
    }
    
    public mutating func insert(_ node: SimNode) {
        nodes[node.fid] = node
    }
    
    @discardableResult
    public mutating func remove(_ fid: UInt16) -> SimNode? {
        nodes.removeValue(forKey: fid)
    }
    
    /// Sorted by fid; the root is not its own child.
    public func children(of fid: UInt16) -> [SimNode] {
        nodes.values
            .filter { $0.parent == fid && $0.fid != fid }
            .sorted { $0.fid < $1.fid }
    }
    
    /// Default name is the zero-padded slot plus `.pcm`, like `056.pcm`.
    public static func sample(slot: UInt16, pcm: [UInt8], name: String? = nil) -> SimNode {
        let digits = String(slot)
        let padded = String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        return SimNode(
            fid: slot,
            parent: soundsFID,
            flags: sampleFlags,
            name: name ?? padded + ".pcm",
            data: pcm
        )
    }
}
