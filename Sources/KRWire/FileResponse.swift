//
//  FileResponse.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore

public struct FileResponse: Equatable, Sendable {
    public let product: Product
    public let id: RequestID
    public let command: UInt8
    public let status: UInt8
    public let payload: [UInt8]
    
    public init(product: Product, id: RequestID, command: UInt8, status: UInt8, payload: [UInt8]) {
        self.product = product
        self.id = id
        self.command = command
        self.status = status
        self.payload = payload
    }
    
    public var isSuccess: Bool {
        status == 0
    }
    
    public var reason: String? {
        guard !isSuccess else { return nil }
        return ASCIITrim.string(payload, set: ASCIITrim.reasonSet)
    }
    
    public func matches(_ id: RequestID, command: SysExCommand) -> Bool {
        self.id == id && self.command == command.rawValue
    }
    
    public func check() throws(KRError) {
        guard isSuccess else {
            throw KRError.statusRejected(status: status, reason: reason ?? "")
        }
    }
}
