//
//  SimDevice+Transfer.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRWire

extension SimDevice {
    private static let putOpenHeaderBytes = 11
    
    mutating func handleGetOpen(_ request: FileRequest) -> [[UInt8]] {
        let payload = request.payload
        guard let fid = SimBytes.u16(payload, at: 2), let offset = SimBytes.u32(payload, at: 4) else {
            return reject(request, "invalid request")
        }
        // Sim-chosen reason.
        guard putSession == nil else { return reject(request, "file busy") }
        guard offset == 0 else { return reject(request, "invalid offset") }
        guard let node = fileSystem.node(fid) else { return reject(request, "invalid id") }
        if getSession?.finished == false {
            getAbandoned = true
        }
        let pages = (node.data.count + Self.getPageBytes - 1) / Self.getPageBytes
        getSession = GetSession(data: node.data, pageCount: pages, finished: node.data.isEmpty)
        var body = SimBytes.be16(fid) + [node.flags] + SimBytes.be32(UInt32(node.data.count))
        body += Array(node.name.utf8) + [0]
        return respond(request, body)
    }
    
    mutating func handleGetData(_ request: FileRequest) -> [[UInt8]] {
        guard let page = SimBytes.u16(request.payload, at: 2) else { return reject(request, "invalid request") }
        // Sim-chosen reason.
        guard var session = getSession else { return reject(request, "no open file") }
        guard Int(page) < session.pageCount else {
            enterDebugLoop(text: Self.readPastEOFText)
            return []
        }
        let start = Int(page) * Self.getPageBytes
        let end = min(start + Self.getPageBytes, session.data.count)
        if Int(page) == session.pageCount - 1 {
            session.finished = true
            getSession = session
        }
        return respond(request, SimBytes.be16(page) + session.data[start..<end])
    }
    
    mutating func handlePutOpen(_ request: FileRequest) -> [[UInt8]] {
        let payload = request.payload
        guard payload.count >= Self.putOpenHeaderBytes,
              let fid = SimBytes.u16(payload, at: 3),
              let parent = SimBytes.u16(payload, at: 5),
              let size = SimBytes.u32(payload, at: 7) else { return reject(request, "invalid request") }
        // Sim-chosen reason.
        guard putSession == nil else { return reject(request, "file busy") }
        let flags = payload[2]
        guard flags != 0x04 else { return reject(request, "can only create files") }
        if getSession?.finished == false {
            getAbandoned = true
        }
        getSession = nil
        if getAbandoned {
            enterDebugLoop(text: Self.abandonedGetText)
            return []
        }
        guard fileSystem.node(parent) != nil else { return reject(request, "invalid id") }
        putSession = PutSession(
            fid: fid,
            parent: parent,
            flags: flags,
            size: Int(size),
            name: SimBytes.cString(payload, at: Self.putOpenHeaderBytes)
        )
        return respond(request, SimBytes.be16(fid))
    }
    
    mutating func handlePutData(_ request: FileRequest) -> [[UInt8]] {
        let payload = request.payload
        guard let page = SimBytes.u16(payload, at: 2) else { return reject(request, "invalid request") }
        // Sim-chosen reasons below.
        guard var session = putSession else { return reject(request, "no open file") }
        guard page == session.nextPage else { return reject(request, "invalid page") }
        let data = Array(payload.dropFirst(4))
        let echo = putEchoesPage ? SimBytes.be16(page) : []
        if data.isEmpty {
            guard session.buffer.count == session.size else { return reject(request, "invalid size") }
            commit(session)
            putSession = nil
            return respond(request, echo)
        }
        guard session.buffer.count + data.count <= session.size else { return reject(request, "invalid size") }
        session.buffer += data
        session.nextPage += 1
        putSession = session
        return respond(request, echo)
    }
    
    private mutating func commit(_ session: PutSession) {
        var data = session.buffer
        let corrupt = !consumeFaults { $0 == .corruptCommit }.isEmpty
        if corrupt, !data.isEmpty {
            data[0] = ~data[0]
        }
        var metadata = fileSystem.node(session.fid)?.metadata ?? [:]
        if ghostMetadata, let ghost = fileSystem.ghosts.removeValue(forKey: session.fid) {
            metadata.merge(ghost) { current, _ in current }
        }
        fileSystem.insert(SimNode(
            fid: session.fid,
            parent: session.parent,
            flags: session.flags,
            name: session.name,
            data: data,
            metadata: metadata
        ))
    }
}
