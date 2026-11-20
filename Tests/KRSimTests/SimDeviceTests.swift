//
//  SimDeviceTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import KRCore
import KRWire
import Testing
@testable import KRSim

struct SimDeviceTests {
    private func be16(_ value: Int) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
    
    private func be32(_ value: Int) -> [UInt8] {
        be16(value >> 16) + be16(value & 0xFFFF)
    }
    
    private func cat(_ parts: [UInt8]...) -> [UInt8] {
        parts.flatMap { $0 }
    }
    
    private func pcm(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8($0 % 251) }
    }
    
    private func makeDevice(slots: [Int: Int] = [:], listEntriesPerPage: Int = 8) -> SimDevice {
        var fileSystem = SimFileSystem()
        for (slot, size) in slots {
            fileSystem.insert(SimFileSystem.sample(slot: UInt16(slot), pcm: pcm(size)))
        }
        return SimDevice(fileSystem: fileSystem, listEntriesPerPage: listEntriesPerPage)
    }
    
    private func frame(_ payload: [UInt8], product: Product = .ep133) -> [UInt8] {
        SysExFrame.fileRequest(product: product, id: RequestID(7), payload: payload)
    }
    
    private func send(_ device: inout SimDevice, _ payload: [UInt8]) throws -> FileResponse? {
        let replies = device.receive(frame(payload))
        guard let reply = replies.first else { return nil }
        guard case .response(let response) = try SysExFrame.parse(reply) else { return nil }
        return response
    }
    
    private func putOpen(fid: Int, size: Int, flags: UInt8 = 0x05, name: String = "x.pcm") -> [UInt8] {
        cat([0x02, 0x00, flags], be16(fid), be16(1000), be32(size), Array(name.utf8), [0])
    }
    
    private func putAll(_ device: inout SimDevice, fid: Int, data: [UInt8]) throws {
        _ = try send(&device, [0x01, 0x00, 0x00, 0x00, 0x10, 0x00])
        #expect(try send(&device, putOpen(fid: fid, size: data.count))?.status == 0)
        var page = 0
        for start in stride(from: 0, to: data.count, by: 433) {
            let chunk = data[start..<min(start + 433, data.count)]
            #expect(try send(&device, [0x02, 0x01] + be16(page) + chunk)?.status == 0)
            page += 1
        }
        #expect(try send(&device, [0x02, 0x01] + be16(page))?.status == 0)
    }
    
    @Test func initReturnsChunkSize() throws {
        var device = makeDevice()
        let response = try send(&device, [0x01, 0x00, 0x00, 0x00, 0x10, 0x00])
        #expect(response?.status == 0)
        #expect(response?.payload == [0x00, 0x00, 0x00, 0x02, 0x00])
    }
    
    @Test func listPagesEntries() throws {
        var slots: [Int: Int] = [:]
        for slot in 1...10 {
            slots[slot] = 4
        }
        var device = makeDevice(slots: slots)
        let page0 = try send(&device, [0x04] + be16(0) + be16(1000))
        let page1 = try send(&device, [0x04] + be16(1) + be16(1000))
        let page2 = try send(&device, [0x04] + be16(2) + be16(1000))
        #expect(page0?.payload.prefix(2) == [0x00, 0x00])
        // Each entry: fid(2) flags size(4) "00N.pcm" 00 = 15 bytes.
        #expect(page0?.payload.count == 2 + 8 * 15)
        #expect(page1?.payload.prefix(2) == [0x00, 0x01])
        #expect(page1?.payload.count == 2 + 2 * 15)
        #expect(page2?.payload == [0x00, 0x02])
        #expect(try send(&device, [0x04] + be16(0) + be16(9999))?.reason == "invalid id")
    }
    
    @Test func statReportsNode() throws {
        var device = makeDevice(slots: [56: 1234])
        let response = try send(&device, [0x0B] + be16(56))
        let expected = cat(be16(56), be16(1000), [0x1D], be32(1234), Array("056.pcm".utf8), [0])
        #expect(response?.payload == expected)
        #expect(try send(&device, [0x0B] + be16(9999))?.reason == "invalid id")
    }
    
    @Test func getReadsPagesByteExact() throws {
        var device = makeDevice(slots: [56: 700])
        let open = try send(&device, [0x03, 0x00] + be16(56) + be32(0))
        #expect(open?.payload == cat(be16(56), [0x1D], be32(700), Array("056.pcm".utf8), [0]))
        var collected: [UInt8] = []
        var sizes: [Int] = []
        for page in 0..<3 {
            let response = try send(&device, [0x03, 0x01] + be16(page))
            #expect(response?.payload.prefix(2) == be16(page)[...])
            let body = Array(response?.payload.dropFirst(2) ?? [])
            sizes.append(body.count)
            collected += body
        }
        #expect(sizes == [324, 324, 52])
        #expect(collected == pcm(700))
    }
    
    @Test func getPastEOFEntersDebugLoop() throws {
        var device = makeDevice(slots: [56: 700])
        _ = try send(&device, [0x03, 0x00] + be16(56) + be32(0))
        #expect(try send(&device, [0x03, 0x01] + be16(3)) == nil)
        #expect(device.isLooping)
        #expect(device.debugText?.contains("err 82") == true)
    }
    
    @Test func readingOnePageAfterTheLastEntersDebugLoop() throws {
        var device = makeDevice(slots: [56: 700])
        _ = try send(&device, [0x03, 0x00] + be16(56) + be32(0))
        for page in 0..<3 {
            #expect(try send(&device, [0x03, 0x01] + be16(page))?.status == 0)
        }
        #expect(try send(&device, [0x03, 0x01] + be16(3)) == nil)
        #expect(device.isLooping)
        #expect(device.debugText?.contains("err 82") == true)
    }
    
    @Test func readingDataOfAnEmptyFileEntersDebugLoop() throws {
        var device = makeDevice(slots: [56: 0])
        _ = try send(&device, [0x03, 0x00] + be16(56) + be32(0))
        #expect(try send(&device, [0x03, 0x01] + be16(0)) == nil)
        #expect(device.isLooping)
    }
    
    @Test func initAfterACompleteGetDoesNotAbandonIt() throws {
        var device = makeDevice(slots: [56: 700])
        _ = try send(&device, [0x03, 0x00] + be16(56) + be32(0))
        for page in 0..<3 {
            _ = try send(&device, [0x03, 0x01] + be16(page))
        }
        #expect(try send(&device, [0x01, 0x00, 0x00, 0x00, 0x10, 0x00])?.status == 0)
        try putAll(&device, fid: 57, data: pcm(4))
        #expect(!device.isLooping)
        #expect(device.fileSystem.node(57)?.data == pcm(4))
    }
    
    @Test func getRejectsOffsetAndMissingFile() throws {
        var device = makeDevice(slots: [56: 10])
        #expect(try send(&device, [0x03, 0x00] + be16(56) + be32(1))?.reason == "invalid offset")
        #expect(try send(&device, [0x03, 0x00] + be16(9999) + be32(0))?.reason == "invalid id")
    }
    
    @Test func emptyGetDoesNotAbandonStream() throws {
        var device = makeDevice(slots: [56: 0])
        let open = try send(&device, [0x03, 0x00] + be16(56) + be32(0))
        #expect(open?.status == 0)
        try putAll(&device, fid: 57, data: pcm(10))
        #expect(!device.isLooping)
        #expect(device.fileSystem.node(57)?.data == pcm(10))
    }
    
    @Test func abandonedGetBreaksNextPutUntilPowerCycle() throws {
        var device = makeDevice(slots: [56: 700])
        _ = try send(&device, [0x03, 0x00] + be16(56) + be32(0))
        _ = try send(&device, [0x03, 0x01] + be16(0))
        #expect(try send(&device, [0x01, 0x00, 0x00, 0x00, 0x10, 0x00])?.status == 0)
        #expect(try send(&device, [0x0B] + be16(56))?.status == 0)
        #expect(try send(&device, putOpen(fid: 57, size: 4)) == nil)
        #expect(device.isLooping)
        #expect(device.debugText?.contains("err 8200") == true)
        device.powerCycle()
        #expect(!device.isLooping)
        try putAll(&device, fid: 57, data: pcm(4))
        #expect(device.fileSystem.node(57)?.data == pcm(4))
    }
    
    @Test func secondGetOpenAbandonsFirst() throws {
        var device = makeDevice(slots: [56: 700, 57: 700])
        _ = try send(&device, [0x03, 0x00] + be16(56) + be32(0))
        _ = try send(&device, [0x03, 0x01] + be16(0))
        #expect(try send(&device, [0x03, 0x00] + be16(57) + be32(0))?.status == 0)
        #expect(try send(&device, putOpen(fid: 60, size: 4)) == nil)
        #expect(device.debugText?.contains("err 8200") == true)
    }
    
    @Test func getDuringPutIsBusy() throws {
        var device = makeDevice(slots: [56: 700])
        #expect(try send(&device, putOpen(fid: 60, size: 4))?.status == 0)
        #expect(try send(&device, [0x03, 0x00] + be16(56) + be32(0))?.reason == "file busy")
        #expect(try send(&device, [0x02, 0x01] + be16(0) + [1, 2, 3, 4])?.status == 0)
    }
    
    @Test func putStoresBytesAndListsNode() throws {
        var device = makeDevice()
        let data = pcm(1000)
        try putAll(&device, fid: 61, data: data)
        #expect(device.fileSystem.node(61)?.data == data)
        let list = try send(&device, [0x04] + be16(0) + be16(1000))
        let entryBytes = 2 + 1 + 4 + "x.pcm".utf8.count + 1
        #expect(list?.payload.count == 2 + entryBytes)
    }
    
    @Test func putEchoesPageWhenConfigured() throws {
        var device = SimDevice(putEchoesPage: true)
        _ = try send(&device, putOpen(fid: 61, size: 2))
        #expect(try send(&device, [0x02, 0x01] + be16(0) + [1, 2])?.payload == be16(0))
    }
    
    @Test func putRejectsBadRequests() throws {
        var device = makeDevice()
        #expect(try send(&device, putOpen(fid: 61, size: 4, flags: 0x04))?.reason == "can only create files")
        _ = try send(&device, putOpen(fid: 61, size: 4))
        #expect(try send(&device, [0x02, 0x01] + be16(1) + [1])?.reason == "invalid page")
        #expect(try send(&device, [0x02, 0x01] + be16(0) + [1, 2])?.status == 0)
        #expect(try send(&device, [0x02, 0x01] + be16(1))?.reason == "invalid size")
        #expect(try send(&device, [0x02, 0x01] + be16(1) + [1, 2, 3])?.reason == "invalid size")
    }
    
    @Test func deleteRemovesOnlyBareForm() throws {
        var device = makeDevice(slots: [56: 4])
        #expect(try send(&device, [0x06, 0x02] + be16(56))?.status == 0)
        #expect(device.fileSystem.node(56) != nil)
        #expect(try send(&device, [0x06] + be16(56))?.status == 0)
        #expect(device.fileSystem.node(56) == nil)
        #expect(try send(&device, [0x06] + be16(56))?.reason == "invalid id")
    }
    
    @Test func playRecordsFID() throws {
        var device = makeDevice(slots: [56: 4])
        #expect(try send(&device, [0x05, 0x01] + be16(56))?.status == 0)
        #expect(device.playedFIDs == [56])
        #expect(try send(&device, [0x05, 0x01] + be16(9999))?.reason == "invalid id")
    }
    
    @Test func metadataMergesAndFiltersByKey() throws {
        var device = makeDevice(slots: [56: 4])
        let first = Array(#"{"name":"kick"}"#.utf8)
        let second = Array(#"{"sound.pan":-3}"#.utf8)
        #expect(try send(&device, cat([0x07, 0x01], be16(56), first, [0]))?.status == 0)
        #expect(try send(&device, cat([0x07, 0x01], be16(56), second, [0]))?.status == 0)
        let all = try send(&device, [0x07, 0x02] + be16(56) + be16(0))
        #expect(all?.payload == cat(be16(0), Array(#"{"name":"kick","sound.pan":-3}"#.utf8), [0]))
        let one = try send(&device, cat([0x07, 0x02], be16(56), be16(0), Array("name".utf8), [0]))
        #expect(one?.payload == cat(be16(0), Array(#"{"name":"kick"}"#.utf8), [0]))
        #expect(try send(&device, cat([0x07, 0x01], be16(56), Array("[1]".utf8), [0]))?.reason == "invalid json")
        #expect(try send(&device, cat([0x07, 0x01], be16(9999), first, [0]))?.reason == "invalid id")
    }
    
    @Test func metadataPagesLongText() throws {
        var device = makeDevice(slots: [56: 4])
        let value = String(repeating: "a", count: 683)
        let json = Array("{\"k\":\"\(value)\"}".utf8)
        #expect(json.count == 691)
        _ = try send(&device, cat([0x07, 0x01], be16(56), json, [0]))
        for page in 0..<3 {
            let response = try send(&device, [0x07, 0x02] + be16(56) + be16(page))
            #expect((response?.payload.last == 0) == (page == 2))
        }
        #expect(try send(&device, [0x07, 0x02] + be16(56) + be16(3))?.payload == be16(3))
    }
    
    @Test func silenceFaultDropsReply() throws {
        var device = makeDevice(slots: [56: 4])
        device.inject(.silence(opcode: [0x0B]))
        #expect(try send(&device, [0x0B] + be16(56)) == nil)
        device.clearFaults()
        #expect(try send(&device, [0x0B] + be16(56))?.status == 0)
    }
    
    @Test func rejectFaultAnswersWithReason() throws {
        var device = makeDevice(slots: [56: 4])
        device.inject(.reject(opcode: [0x06], reason: "nope"))
        let response = try send(&device, [0x06] + be16(56))
        #expect(response?.status == 1)
        #expect(response?.reason == "nope")
        #expect(device.fileSystem.node(56) != nil)
    }
    
    @Test func debugLoopFaultSilencesEverything() throws {
        var device = makeDevice(slots: [56: 4])
        device.inject(.debugLoop(onOpcode: [0x05, 0x01], text: "err boom"))
        #expect(try send(&device, [0x05, 0x01] + be16(56)) == nil)
        #expect(device.isLooping)
        #expect(device.debugText == "err boom")
        #expect(try send(&device, [0x01, 0x00, 0x00, 0x00, 0x10, 0x00]) == nil)
    }
    
    @Test func ignoresOtherProductsAndGarbage() throws {
        var device = makeDevice()
        #expect(device.receive(frame([0x01, 0, 0, 0, 0x10, 0], product: .ep40)).isEmpty)
        #expect(device.receive([0xF0, 0xF7]).isEmpty)
        #expect(device.receive([]).isEmpty)
    }
    
    @Test func ackWithoutEffectKeepsDeleteTarget() throws {
        var device = makeDevice(slots: [6: 4])
        device.inject(.ackWithoutEffect(opcode: [0x06]))
        #expect(try send(&device, [0x06] + be16(6))?.status == 0)
        #expect(device.fileSystem.node(6) != nil)
    }
    
    @Test func ackWithoutEffectKeepsMetadata() throws {
        var device = makeDevice(slots: [7: 4])
        let json = Array(#"{"name":"a"}"#.utf8)
        _ = try send(&device, cat([0x07, 0x01], be16(7), json, [0]))
        device.inject(.ackWithoutEffect(opcode: [0x07, 0x01]))
        let other = Array(#"{"name":"b"}"#.utf8)
        #expect(try send(&device, cat([0x07, 0x01], be16(7), other, [0]))?.status == 0)
        #expect(device.fileSystem.node(7)?.metadata == ["name": "\"a\""])
    }
    
    @Test func corruptCommitFlipsFirstByte() throws {
        var device = makeDevice()
        device.inject(.corruptCommit)
        let data = pcm(100)
        try putAll(&device, fid: 61, data: data)
        let stored = try #require(device.fileSystem.node(61)?.data)
        #expect(stored[0] != data[0])
        #expect(Array(stored.dropFirst()) == Array(data.dropFirst()))
    }
    
    @Test func skipAndTimesLimitAFault() throws {
        var device = makeDevice(slots: [56: 4])
        device.inject(.silence(opcode: [0x0B]), skip: 1, times: 1)
        #expect(try send(&device, [0x0B] + be16(56))?.status == 0)
        #expect(try send(&device, [0x0B] + be16(56)) == nil)
        #expect(try send(&device, [0x0B] + be16(56))?.status == 0)
    }
    
    @Test func ghostMetadataSurvivesDeleteAndMergesOnPut() throws {
        var device = SimDevice(fileSystem: {
            var fileSystem = SimFileSystem()
            var node = SimFileSystem.sample(slot: 9, pcm: pcm(4))
            node.metadata = ["name": "\"kick\""]
            fileSystem.insert(node)
            return fileSystem
        }(), ghostMetadata: true)
        #expect(try send(&device, [0x06] + be16(9))?.status == 0)
        let list = try send(&device, [0x04] + be16(0) + be16(1000))
        #expect(list?.payload == be16(0))
        let ghost = try send(&device, [0x07, 0x02] + be16(9) + be16(0))
        #expect(ghost?.payload == cat(be16(0), Array(#"{"name":"kick"}"#.utf8), [0]))
        try putAll(&device, fid: 9, data: pcm(10))
        #expect(device.fileSystem.node(9)?.metadata == ["name": "\"kick\""])
    }
    
    @Test func withoutGhostMetadataDeletedSlotIsGone() throws {
        var device = makeDevice(slots: [9: 4])
        _ = try send(&device, cat([0x07, 0x01], be16(9), Array(#"{"name":"kick"}"#.utf8), [0]))
        _ = try send(&device, [0x06] + be16(9))
        #expect(try send(&device, [0x07, 0x02] + be16(9) + be16(0))?.reason == "invalid id")
    }
}
