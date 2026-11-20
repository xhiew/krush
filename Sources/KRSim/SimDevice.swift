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
    
    struct FaultRule: Sendable {
        var fault: SimFault
        var skip: Int
        /// `nil` never expires.
        var remaining: Int?
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
    public let ghostMetadata: Bool
    
    public internal(set) var fileSystem: SimFileSystem
    public private(set) var isLooping = false
    public private(set) var debugText: String?
    public internal(set) var playedFIDs: [UInt16] = []
    
    var faults: [FaultRule] = []
    var ackWithoutEffectActive = false
    var getSession: GetSession?
    var putSession: PutSession?
    var getAbandoned = false
    
    public init(
        product: Product = .ep133,
        fileSystem: SimFileSystem = .init(),
        chunkSize: UInt32 = 512,
        listEntriesPerPage: Int = 8,
        putEchoesPage: Bool = false,
        metadataPageBytes: Int = 300,
        ghostMetadata: Bool = false
    ) {
        self.product = product
        self.fileSystem = fileSystem
        self.chunkSize = chunkSize
        self.listEntriesPerPage = max(1, listEntriesPerPage)
        self.putEchoesPage = putEchoesPage
        self.metadataPageBytes = max(1, metadataPageBytes)
        self.ghostMetadata = ghostMetadata
    }
    
    public mutating func inject(_ fault: SimFault) {
        faults.append(FaultRule(fault: fault, skip: 0, remaining: nil))
    }
    
    /// Ignores the first `skip` matches, then applies the fault `times` times (`nil` = for good).
    public mutating func inject(_ fault: SimFault, skip: Int, times: Int?) {
        faults.append(FaultRule(fault: fault, skip: max(0, skip), remaining: times.map { max(0, $0) }))
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
        let active = consumeFaults { fault in
            switch fault {
            case .silence(let opcode), .reject(let opcode, _), .debugLoop(let opcode, _), .ackWithoutEffect(let opcode):
                return payload.starts(with: opcode)
            case .corruptCommit:
                return false
            }
        }
        for fault in active {
            if case .debugLoop(_, let text) = fault {
                enterDebugLoop(text: text)
                return []
            }
        }
        if active.contains(where: { if case .silence = $0 { true } else { false } }) {
            return []
        }
        for fault in active {
            if case .reject(_, let reason) = fault {
                return reject(request, reason)
            }
        }
        ackWithoutEffectActive = active.contains { if case .ackWithoutEffect = $0 { true } else { false } }
        defer { ackWithoutEffectActive = false }
        return handle(request)
    }
    
    /// Every matching rule counts this occurrence; the returned faults are the ones in effect for it.
    mutating func consumeFaults(matching matches: (SimFault) -> Bool) -> [SimFault] {
        var active: [SimFault] = []
        for index in faults.indices where matches(faults[index].fault) {
            if faults[index].skip > 0 {
                faults[index].skip -= 1
                continue
            }
            if let remaining = faults[index].remaining {
                guard remaining > 0 else { continue }
                faults[index].remaining = remaining - 1
            }
            active.append(faults[index].fault)
        }
        return active
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
        guard let removed = fileSystem.node(fid) else { return reject(request, "invalid id") }
        if ackWithoutEffectActive {
            return respond(request)
        }
        fileSystem.remove(fid)
        if ghostMetadata {
            fileSystem.ghosts[fid] = removed.metadata
        }
        return respond(request)
    }
    
    private mutating func handlePlay(_ request: FileRequest) -> [[UInt8]] {
        guard let fid = SimBytes.u16(request.payload, at: 2) else { return reject(request, "invalid request") }
        guard fileSystem.node(fid) != nil else { return reject(request, "invalid id") }
        playedFIDs.append(fid)
        return respond(request)
    }
}
