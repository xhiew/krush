//
//  FileRequest.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

public struct FileRequest: Equatable, Sendable {
    public let product: Product
    public let id: RequestID
    public let command: UInt8
    public let payload: [UInt8]
    
    public init(product: Product, id: RequestID, command: UInt8, payload: [UInt8]) {
        self.product = product
        self.id = id
        self.command = command
        self.payload = payload
    }
}
