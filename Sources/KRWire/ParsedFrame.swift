//
//  ParsedFrame.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

public enum ParsedFrame: Equatable, Sendable {
    case request(FileRequest)
    case response(FileResponse)
    case debug(DebugFrame)
    case unrelated
}
