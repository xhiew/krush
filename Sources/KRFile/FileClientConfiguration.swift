//
//  FileClientConfiguration.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

public struct FileClientConfiguration: Sendable {
    public var requestTimeout: Duration
    public var debugGrace: Duration
    public var drainWindow: Duration
    public var haltedPreflight: Duration
    public var idleReinit: Duration
    public var initFlags: UInt8
    public var maxResponseLength: UInt32
    
    public init(
        requestTimeout: Duration = .seconds(3),
        debugGrace: Duration = .milliseconds(2500),
        drainWindow: Duration = .milliseconds(100),
        haltedPreflight: Duration = .milliseconds(1200),
        idleReinit: Duration = .seconds(5),
        initFlags: UInt8 = 0x01,
        maxResponseLength: UInt32 = 4 * 1024 * 1024
    ) {
        self.requestTimeout = requestTimeout
        self.debugGrace = debugGrace
        self.drainWindow = drainWindow
        self.haltedPreflight = haltedPreflight
        self.idleReinit = idleReinit
        self.initFlags = initFlags
        self.maxResponseLength = maxResponseLength
    }
}
