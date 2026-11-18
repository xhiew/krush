//
//  FileClient+Transfer.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRCore

extension FileClient {
    private static let maxReservedBytes = 4 * 1024 * 1024
    
    public func read(
        fid: UInt16,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws(KRError) -> FileContent {
        try await withGate { () async throws(KRError) -> FileContent in
            try self.ensureNotInterrupted()
            try await self.reinitIfIdle()
            return try await self.readLocked(fid: fid, progress: progress)
        }
    }
    
    /// Gate holder only. The lock is taken before the open frame and kept on any failure after it was sent.
    private func readLocked(
        fid: UInt16,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws(KRError) -> FileContent {
        var openSent = false
        var openRejected = false
        try ensureCanStartTransfer()
        markTransferInterrupted()
        do throws(KRError) {
            let openPayload: [UInt8]
            do throws(KRError) {
                openPayload = try await performRequest(
                    FileCodec.getOpenRequest(fid: fid),
                    timeout: nil,
                    didSend: &openSent
                )
            } catch {
                if case .statusRejected = error {
                    openRejected = true
                }
                throw error
            }
            let header = try FileCodec.getOpen(openPayload, fid: fid)
            let size = Int(header.size)
            let pageCount = FileCodec.getPageCount(size: header.size)
            guard pageCount <= Int(UInt16.max) + 1 else {
                throw KRError.malformedResponse(reason: "file has \(pageCount) pages")
            }
            var data: [UInt8] = []
            data.reserveCapacity(min(size, Self.maxReservedBytes))
            for index in 0..<pageCount {
                if Task.isCancelled {
                    throw KRError.cancelled
                }
                let page = UInt16(index)
                let payload = try await performRequest(FileCodec.getDataRequest(page: page), timeout: nil)
                data += try FileCodec.getDataPage(payload, expectedPage: page)
                progress?(TransferProgress(completed: min(data.count, size), total: size))
                if index < pageCount - 1 {
                    try await pause(configuration.pageDelay)
                }
            }
            guard data.count >= size else {
                throw KRError.malformedResponse(reason: "short read: \(data.count) of \(size) bytes")
            }
            releaseTransferLock()
            return FileContent(fid: fid, flags: header.flags, name: header.name, data: Array(data.prefix(size)))
        } catch {
            if openRejected || !openSent {
                releaseTransferLock()
            } else {
                // clearInterruptedTransfer() may have run while the open send was suspended.
                markTransferInterrupted()
            }
            throw error
        }
    }
    
    @_spi(UnsafeDeviceLab) public func write(
        fid: UInt16,
        parent: UInt16,
        name: String,
        flags: FileCreateFlags,
        data: [UInt8],
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws(KRError) {
        guard let size = UInt32(exactly: data.count) else {
            throw KRError.invalidArgument(reason: "data has \(data.count) bytes")
        }
        _ = try Self.putPlan(
            flags: flags, fid: fid, parent: parent, size: size, name: name,
            dataCount: data.count, chunkSize: chunkSize
        )
        try await withGate { () async throws(KRError) -> Void in
            try await self.prepareMutation()
            try await self.initialize()
            try await self.writeLocked(
                fid: fid, parent: parent, name: name, flags: flags, data: data, size: size, progress: progress
            )
        }
    }
    
    /// Gate holder only. Once the open frame is sent the lock stays until the EOF page is acknowledged.
    private func writeLocked(
        fid: UInt16,
        parent: UInt16,
        name: String,
        flags: FileCreateFlags,
        data: [UInt8],
        size: UInt32,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws(KRError) {
        // Re-checked here: the chunk size may have changed with the INIT sent after the first check.
        let (open, pageBytes, pageCount) = try Self.putPlan(
            flags: flags, fid: fid, parent: parent, size: size, name: name,
            dataCount: data.count, chunkSize: chunkSize
        )
        var openSent = false
        var openRejected = false
        try ensureCanStartTransfer()
        markTransferInterrupted()
        do throws(KRError) {
            do throws(KRError) {
                let echo = try await performRequest(open, timeout: configuration.transferTimeout, didSend: &openSent)
                try FileCodec.checkPutOpenEcho(echo, fid: fid)
            } catch {
                if case .statusRejected = error {
                    openRejected = true
                }
                throw error
            }
            for index in 0..<pageCount {
                if Task.isCancelled {
                    throw KRError.cancelled
                }
                let start = index * pageBytes
                let end = min(start + pageBytes, data.count)
                _ = try await performRequest(
                    FileCodec.putDataRequest(page: UInt16(index), bytes: data[start..<end]),
                    timeout: configuration.transferTimeout
                )
                try await pause(configuration.pageDelay)
                progress?(TransferProgress(completed: end, total: data.count))
            }
            if Task.isCancelled {
                throw KRError.cancelled
            }
            _ = try await performRequest(
                FileCodec.putDataRequest(page: UInt16(pageCount), bytes: []),
                timeout: configuration.transferTimeout
            )
        } catch {
            if openRejected || !openSent {
                releaseTransferLock()
            } else {
                // clearInterruptedTransfer() may have run while the open send was suspended.
                markTransferInterrupted()
            }
            throw error
        }
        // The file is committed: later failures are reported but never lock, and a cancel changes nothing.
        releaseTransferLock()
        try await listen(for: configuration.commitDelay, session: currentSession)
        try await initialize(honorsCancellation: false)
    }
    
    private static func putPlan(
        flags: FileCreateFlags,
        fid: UInt16,
        parent: UInt16,
        size: UInt32,
        name: String,
        dataCount: Int,
        chunkSize: Int
    ) throws(KRError) -> (open: [UInt8], pageBytes: Int, pageCount: Int) {
        let pageBytes = FileCodec.putPayloadBytes(chunkSize: chunkSize)
        let open = try FileCodec.putOpenRequest(
            flags: flags, fid: fid, parent: parent, size: size, name: name, maxPayload: pageBytes
        )
        let pageCount = (dataCount + pageBytes - 1) / pageBytes
        guard pageCount <= Int(UInt16.max) else {
            throw KRError.invalidArgument(reason: "data needs \(pageCount) pages")
        }
        return (open, pageBytes, pageCount)
    }
}
