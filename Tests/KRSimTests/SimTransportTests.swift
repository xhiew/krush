//
//  SimTransportTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRCore
import KRWire
import Testing
@testable import KRSim

@Suite(.serialized)
struct SimTransportTests {
    private actor Collector {
        private(set) var frames: [[UInt8]] = []
        private(set) var finished = false
        private var task: Task<Void, Never>?
        
        func start(_ stream: AsyncStream<[UInt8]>) {
            task = Task {
                for await frame in stream {
                    frames.append(frame)
                }
                finished = true
            }
        }
        
        func stop() {
            task?.cancel()
        }
        
        var debugTexts: [String] {
            frames.compactMap { frame in
                guard case .debug(let debug)? = try? SysExFrame.parse(frame) else { return nil }
                return debug.text
            }
        }
    }
    
    private func request(_ payload: [UInt8], id: UInt16 = 1) -> [UInt8] {
        SysExFrame.fileRequest(product: .ep133, id: RequestID(id), payload: payload)
    }
    
    private func makeSim(
        replyDelay: Duration = .zero,
        debugPeriod: Duration = .milliseconds(1030)
    ) -> SimTransport {
        var fileSystem = SimFileSystem()
        fileSystem.insert(SimFileSystem.sample(slot: 56, pcm: [1, 2, 3]))
        return SimTransport(
            device: SimDevice(fileSystem: fileSystem),
            replyDelay: replyDelay,
            debugPeriod: debugPeriod
        )
    }
    
    private func connected(_ sim: SimTransport) async throws -> Collector {
        let collector = Collector()
        await collector.start(try await sim.connect())
        return collector
    }
    
    private func waitForFrames(_ collector: Collector, count: Int) async {
        for _ in 0..<400 where await collector.frames.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    
    private let statRequest: [UInt8] = [0x0B, 0x00, 0x38]
    private let listRequest: [UInt8] = [0x04, 0x00, 0x00, 0x03, 0xE8]
    
    @Test func repliesToRequests() async throws {
        let sim = makeSim()
        let collector = try await connected(sim)
        try await sim.send(request(statRequest))
        await waitForFrames(collector, count: 1)
        let frames = await collector.frames
        guard case .response(let response)? = try? SysExFrame.parse(frames.first ?? []) else {
            Issue.record("no response")
            return
        }
        #expect(response.status == 0)
        #expect(response.id == RequestID(1))
        #expect(await sim.sentFrames == [request(statRequest)])
        await sim.disconnect()
    }
    
    @Test func connectAndSendStateErrors() async throws {
        let sim = makeSim()
        await #expect(throws: KRError.disconnected) {
            try await sim.send([0xF0, 0xF7])
        }
        _ = try await sim.connect()
        await #expect(throws: KRError.alreadyConnected) {
            _ = try await sim.connect()
        }
        await sim.disconnect()
    }
    
    @Test func replyDelayHoldsReplies() async throws {
        let sim = makeSim(replyDelay: .milliseconds(120))
        let collector = try await connected(sim)
        try await sim.send(request(statRequest))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await collector.frames.isEmpty)
        await waitForFrames(collector, count: 1)
        #expect(await collector.frames.count == 1)
        await sim.disconnect()
    }
    
    @Test func debugLoopEmitsPeriodically() async throws {
        let sim = makeSim(debugPeriod: .milliseconds(50))
        let collector = try await connected(sim)
        await sim.enterDebugLoop(text: "err test")
        try await Task.sleep(for: .milliseconds(250))
        let texts = await collector.debugTexts
        #expect(texts.count >= 3)
        #expect(texts.allSatisfy { $0 == "err test" })
        await sim.disconnect()
    }
    
    @Test func debugLoopSurvivesReconnectUntilPowerCycle() async throws {
        let sim = makeSim(debugPeriod: .milliseconds(50))
        _ = try await connected(sim)
        await sim.enterDebugLoop(text: "err test")
        await sim.disconnect()
        let second = try await connected(sim)
        try await Task.sleep(for: .milliseconds(130))
        #expect(await second.debugTexts.count >= 1)
        await sim.powerCycle()
        let third = try await connected(sim)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await third.debugTexts.isEmpty)
        #expect(await sim.device.isLooping == false)
        await sim.disconnect()
    }
    
    @Test func firstDebugFrameWaitsOnePeriod() async throws {
        let sim = makeSim(debugPeriod: .milliseconds(200))
        let collector = try await connected(sim)
        await sim.enterDebugLoop(text: "err test")
        try await Task.sleep(for: .milliseconds(120))
        #expect(await collector.debugTexts.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await collector.debugTexts.count >= 1)
        await sim.disconnect()
    }
    
    @Test func overlappingRequestsEnterLoop() async throws {
        let sim = makeSim(replyDelay: .milliseconds(50))
        _ = try await connected(sim)
        try await sim.send(request(statRequest, id: 1))
        try await sim.send(request(listRequest, id: 2))
        let device = await sim.device
        #expect(device.isLooping)
        #expect(device.debugText?.contains("err lfs 6327") == true)
        await sim.disconnect()
    }
    
    @Test func silencedRequestDoesNotCountAsPending() async throws {
        let sim = makeSim(replyDelay: .milliseconds(50))
        await sim.inject(.silence(opcode: [0x0B]))
        let collector = try await connected(sim)
        try await sim.send(request(statRequest, id: 1))
        try await sim.send(request(listRequest, id: 2))
        await waitForFrames(collector, count: 1)
        #expect(await collector.frames.count == 1)
        #expect(await sim.device.isLooping == false)
        await sim.disconnect()
    }
    
    @Test func unplugFinishesStream() async throws {
        let sim = makeSim()
        let collector = try await connected(sim)
        await sim.unplug()
        for _ in 0..<100 where await !collector.finished {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await collector.finished)
    }

    @Test(.timeLimit(.minutes(1)))
    func waitForSentReturnsWhenTheStreamCloses() async throws {
        let sim = makeSim()
        _ = try await connected(sim)
        let waiter = Task { await sim.waitForSent(count: 5) }
        try await Task.sleep(for: .milliseconds(20))
        await sim.unplug()
        await waiter.value
        #expect(await sim.sentFrames.count < 5)
    }
    
    @Test func injectSkipTimesAndClearFaults() async throws {
        let sim = makeSim()
        let collector = try await connected(sim)
        await sim.inject(.silence(opcode: [0x0B]), skip: 1, times: 1)
        for id in 1...3 {
            try await sim.send(request(statRequest, id: UInt16(id)))
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await collector.frames.count == 2)
        await sim.inject(.silence(opcode: [0x0B]))
        await sim.clearFaults()
        try await sim.send(request(statRequest, id: 4))
        await waitForFrames(collector, count: 3)
        #expect(await collector.frames.count == 3)
        await sim.disconnect()
    }
}
