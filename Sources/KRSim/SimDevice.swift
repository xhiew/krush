//
//  SimDevice.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRWire

/// Pure state machine of an EP-133 FILE endpoint; reasons not found in the references are sim-chosen.
/// Ref: ep-series-sysex `docs/file-protocol.md`, `docs/errors.md`.
public struct SimDevice: Sendable {
    struct GetSession: Sendable {
        var data: [UInt8]
        var pageCount: Int
        /// The last page was served; kept so a read past EOF can be told apart from a read with no open file.
        var finished = false
    }
    
    struct PutSession: Sendable {
        var fid: UInt16
        var parent: UInt16
        var flags: UInt8
        var size: Int
        var name: String
        var nextPage: UInt16 = 0
        var buffer: [UInt8] = []
    }
    
    static let getPageBytes = 324
    static let overlapText = "err lfs 6327 2_5_1"
    static let readPastEOFText = "err 82 2_5_1"
    static let abandonedGetText = "err 8200 100f0696 10040a15 2c006008 2_5_1"
    
    public let product: Product
    public let chunkSize: UInt32
    public let listEntriesPerPage: Int
    public var putEchoesPage: Bool
    public var metadataPageBytes: Int
    
    public internal(set) var fileSystem: SimFileSystem
    public private(set) var isLooping = false
    public private(set) var debugText: String?
    public internal(set) var playedFIDs: [UInt16] = []
    
    var faults: [SimFault] = []
    var getSession: GetSession?
    var putSession: PutSession?
    var getAbandoned = false
    
    public init(
        product: Product = .ep133,
        fileSystem: SimFileSystem = .init(),
        chunkSize: UInt32 = 512,
        listEntriesPerPage: Int = 8,
        putEchoesPage: Bool = false,
        metadataPageBytes: Int = 300
    ) {
        self.product = product
        self.fileSystem = fileSystem
        self.chunkSize = chunkSize
        self.listEntriesPerPage = max(1, listEntriesPerPage)
        self.putEchoesPage = putEchoesPage
        self.metadataPageBytes = max(1, metadataPageBytes)
    }
    
    public mutating func inject(_ fault: SimFault) {
        faults.append(fault)
    }
    
    public mutating func clearFaults() {
        faults.removeAll()
    }
    
    public mutating func enterDebugLoop(text: String) {
        isLooping = true
        debugText = text
        getSession = nil
        putSession = nil
    }
    
    /// Keeps the filesystem and injected faults.
    public mutating func powerCycle() {
        isLooping = false
        debugText = nil
        getSession = nil
        putSession = nil
        getAbandoned = false
    }
    
    /// Replies are zero or more complete response frames.
    public mutating func receive(_ frame: [UInt8]) -> [[UInt8]] {
        guard case .request(let request)? = try? SysExFrame.parse(frame),
              request.product == product,
              request.command == SysExCommand.file.rawValue,
              !isLooping else { return [] }
        let payload = request.payload
        if let loop = faults.compactMap({ fault -> String? in
            guard case .debugLoop(let opcode, let text) = fault, payload.starts(with: opcode) else { return nil }
            return text
        }).first {
            enterDebugLoop(text: loop)
            return []
        }
        if faults.contains(where: { fault in
            guard case .silence(let opcode) = fault else { return false }
            return payload.starts(with: opcode)
        }) {
            return []
        }
        for fault in faults {
            if case .reject(let opcode, let reason) = fault, payload.starts(with: opcode) {
                return reject(request, reason)
            }
        }
        return handle(request)
    }
    
    func respond(_ request: FileRequest, status: UInt8 = 0, _ payload: [UInt8] = []) -> [[UInt8]] {
        [SysExFrame.fileResponse(product: product, id: request.id, status: status, payload: payload)]
    }
    
    func reject(_ request: FileRequest, _ reason: String) -> [[UInt8]] {
        respond(request, status: 1, Array(reason.utf8))
    }
    
    private mutating func handle(_ request: FileRequest) -> [[UInt8]] {
        let payload = request.payload
        guard let opcode = payload.first else { return reject(request, "invalid request") }
        let sub = payload.count > 1 ? payload[1] : nil
        switch (opcode, sub) {
        case (0x01, _): return handleInit(request)
        case (0x02, 0x00): return handlePutOpen(request)
        case (0x02, 0x01): return handlePutData(request)
        case (0x03, 0x00): return handleGetOpen(request)
        case (0x03, 0x01): return handleGetData(request)
        case (0x04, _): return handleList(request)
        case (0x05, 0x01): return handlePlay(request)
        case (0x06, _): return handleDelete(request)
        case (0x07, 0x01): return handleMetadataSet(request)
        case (0x07, 0x02): return handleMetadataGet(request)
        case (0x0B, _): return handleStat(request)
        default: return reject(request, "unknown command")
        }
    }
    
    private mutating func handleInit(_ request: FileRequest) -> [[UInt8]] {
        if getSession?.finished == false {
            getAbandoned = true
        }
        getSession = nil
        putSession = nil
        return respond(request, [0x00] + SimBytes.be32(chunkSize))
    }
    
    private func handleList(_ request: FileRequest) -> [[UInt8]] {
        guard let page = SimBytes.u16(request.payload, at: 1),
              let node = SimBytes.u16(request.payload, at: 3) else { return reject(request, "invalid request") }
        guard fileSystem.node(node) != nil else { return reject(request, "invalid id") }
        let start = Int(page) * listEntriesPerPage
        let children = fileSystem.children(of: node)
        var body = SimBytes.be16(page)
        for child in children.dropFirst(start).prefix(listEntriesPerPage) {
            body += SimBytes.be16(child.fid) + [child.flags] + SimBytes.be32(UInt32(child.data.count))
            body += Array(child.name.utf8) + [0]
        }
        return respond(request, body)
    }
    
    private func handleStat(_ request: FileRequest) -> [[UInt8]] {
        guard let fid = SimBytes.u16(request.payload, at: 1) else { return reject(request, "invalid request") }
        guard let node = fileSystem.node(fid) else { return reject(request, "invalid id") }
        var body = SimBytes.be16(node.fid) + SimBytes.be16(node.parent) + [node.flags]
        body += SimBytes.be32(UInt32(node.data.count)) + Array(node.name.utf8) + [0]
        return respond(request, body)
    }
    
    /// `06 fid` deletes; `06 02 fid` answers status 0 and leaves the node (file-protocol.md:44-51).
    private mutating func handleDelete(_ request: FileRequest) -> [[UInt8]] {
        let payload = request.payload
        if payload.count == 4, payload[1] == 0x02 {
            return respond(request)
        }
        guard payload.count == 3, let fid = SimBytes.u16(payload, at: 1) else {
            return reject(request, "invalid request")
        }
        guard fileSystem.remove(fid) != nil else { return reject(request, "invalid id") }
        return respond(request)
    }
    
    private mutating func handlePlay(_ request: FileRequest) -> [[UInt8]] {
        guard let fid = SimBytes.u16(request.payload, at: 2) else { return reject(request, "invalid request") }
        guard fileSystem.node(fid) != nil else { return reject(request, "invalid id") }
        playedFIDs.append(fid)
        return respond(request)
    }
}
