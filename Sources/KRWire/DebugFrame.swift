//
//  DebugFrame.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import KRCore

public struct DebugFrame: Equatable, Sendable {
    public let product: Product
    public let text: String
    
    public init(product: Product, text: String) {
        self.product = product
        self.text = text
    }
    
    public var error: KRError {
        .deviceDebugFrame(text: text)
    }
}
