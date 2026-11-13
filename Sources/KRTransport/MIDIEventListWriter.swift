//
//  MIDIEventListWriter.swift
//  Krush
//
//  Created by xhiew on 13/11/26.
//

import CoreMIDI
import KRCore

enum MIDIEventListWriter {
    private static let listHeaderSize = 8
    /// `MIDIEventPacket` header (12) + two data words (8) + alignment slack.
    private static let packetSize = 24
    
    static func send(words: [UInt32], port: MIDIPortRef, destination: MIDIEndpointRef) throws(KRError) {
        guard words.count >= 2 else { return }
        try withEventList(words: words) { list throws(KRError) in
            try CoreMIDIClient.check(MIDISendEventList(port, destination, list), "MIDISendEventList")
        }
    }
    
    static func withEventList<Result>(
        words: [UInt32],
        _ body: (UnsafePointer<MIDIEventList>) throws(KRError) -> Result
    ) throws(KRError) -> Result {
        let packetCount = words.count / 2
        let bufferSize = max(MemoryLayout<MIDIEventList>.size, listHeaderSize + packetCount * packetSize)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<MIDIEventList>.alignment
        )
        defer { buffer.deallocate() }
        let list = buffer.bindMemory(to: MIDIEventList.self, capacity: 1)
        var current = MIDIEventListInit(list, ._1_0)
        for packet in 0..<packetCount {
            let added = words.withUnsafeBufferPointer { pointer in
                pointer.baseAddress.flatMap {
                    MIDIEventListAdd(list, bufferSize, current, 0, 2, $0 + packet * 2)
                }
            }
            guard let added else {
                throw .transportFailure(operation: "MIDIEventListAdd", status: -1)
            }
            current = added
        }
        return try body(list)
    }
}
