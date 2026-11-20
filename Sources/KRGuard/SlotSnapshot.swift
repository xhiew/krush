//
//  SlotSnapshot.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import KRFile

/// What preflight read from the device for one slot.
struct SlotSnapshot {
    let fid: UInt16
    let present: Bool
    let stat: FileStat?
    let metadataJSON: String?
    let generation: UInt64
}
