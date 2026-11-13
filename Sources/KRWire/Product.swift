//
//  Product.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

/// A struct, not an enum, so unknown products (e.g. EP-1320) still parse.
public struct Product: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
    
    public static let ep133 = Product(rawValue: 0x33)
    public static let ep40 = Product(rawValue: 0x3C)
}
