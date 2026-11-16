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
    public var transferTimeout: Duration
    public var deleteTimeout: Duration
    public var pageDelay: Duration
    public var commitDelay: Duration
    public var mutationPreflight: Duration
    
    public init(
        requestTimeout: Duration = .seconds(3),
        debugGrace: Duration = .milliseconds(2500),
        drainWindow: Duration = .milliseconds(100),
        haltedPreflight: Duration = .milliseconds(1200),
        idleReinit: Duration = .seconds(5),
        initFlags: UInt8 = 0x01,
        maxResponseLength: UInt32 = 4 * 1024 * 1024,
        transferTimeout: Duration = .seconds(15),
        deleteTimeout: Duration = .seconds(10),
        pageDelay: Duration = .milliseconds(6),
        commitDelay: Duration = .milliseconds(50),
        mutationPreflight: Duration = .milliseconds(1200)
    ) {
        self.requestTimeout = requestTimeout
        self.debugGrace = debugGrace
        self.drainWindow = drainWindow
        self.haltedPreflight = haltedPreflight
        self.idleReinit = idleReinit
        self.initFlags = initFlags
        self.maxResponseLength = maxResponseLength
        self.transferTimeout = transferTimeout
        self.deleteTimeout = deleteTimeout
        self.pageDelay = pageDelay
        self.commitDelay = commitDelay
        self.mutationPreflight = mutationPreflight
    }
}
