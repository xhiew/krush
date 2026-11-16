//
//  TransferProgress.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

public struct TransferProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    
    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}
