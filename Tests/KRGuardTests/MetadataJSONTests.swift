//
//  MetadataJSONTests.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Testing
@testable import KRGuard

struct MetadataJSONTests {
    @Test func parsesAndSerializesCompactWithSortedKeys() throws {
        let json = try #require(MetadataJSON(parsing: #"{ "b": 2, "a": "x", "c": true, "d": null }"#))
        #expect(json.serialized == #"{"a":"x","b":2,"c":true,"d":null}"#)
        #expect(json.keys == ["a", "b", "c", "d"])
    }
    
    @Test func rejectsNestedContainersAndNonObjects() {
        #expect(MetadataJSON(parsing: #"{"a":{}}"#) == nil)
        #expect(MetadataJSON(parsing: #"{"a":[1]}"#) == nil)
        #expect(MetadataJSON(parsing: "[]") == nil)
        #expect(MetadataJSON(parsing: "3") == nil)
        #expect(MetadataJSON(parsing: "") == nil)
    }
    
    @Test func comparesNumbersBySemantics() throws {
        let integer = try #require(MetadataJSON(parsing: #"{"samplerate":46875}"#))
        let decimal = try #require(MetadataJSON(parsing: #"{"samplerate":46875.0}"#))
        #expect(integer == decimal)
        #expect(integer.serialized == decimal.serialized)
    }
    
    @Test func keepsBooleanDistinctFromNumber() throws {
        let flag = try #require(MetadataJSON(parsing: #"{"a":true}"#))
        let number = try #require(MetadataJSON(parsing: #"{"a":1}"#))
        #expect(flag != number)
    }
    
    @Test func escapesStringValuesWithoutEscapingSlashes() throws {
        let json = try #require(MetadataJSON(parsing: #"{"name":"a\"b/c"}"#))
        #expect(json.serialized == #"{"name":"a\"b/c"}"#)
        #expect(MetadataJSON(parsing: json.serialized) == json)
    }
    
    @Test func removesAndRestrictsKeys() throws {
        let json = try #require(MetadataJSON(parsing: #"{"a":1,"b":2,"crc":3}"#))
        #expect(json.removing(keys: ["crc"]).keys == ["a", "b"])
        #expect(json.restricting(to: ["b", "missing"]).keys == ["b"])
    }
    
    @Test func splitsIntoPartsThatMergeBack() throws {
        var entries: [String: MetadataJSON.Value] = [:]
        for index in 0..<8 {
            entries["key\(index)"] = .string(String(repeating: "v", count: 110))
        }
        let json = MetadataJSON(entries: entries)
        #expect(json.serialized.utf8.count >= 900)
        let parts = try #require(json.split(maxBytes: 428))
        #expect(parts.count >= 3)
        #expect(parts.allSatisfy { $0.utf8.count <= 428 })
        var merged: [String: MetadataJSON.Value] = [:]
        for part in parts {
            let parsed = try #require(MetadataJSON(parsing: part))
            merged.merge(parsed.entries) { _, new in new }
        }
        #expect(merged == json.entries)
    }
    
    @Test func splitFailsWhenOnePairIsTooLong() {
        let json = MetadataJSON(entries: ["key": .string(String(repeating: "v", count: 500))])
        #expect(json.split(maxBytes: 428) == nil)
    }
    
    @Test func splitOfEmptyObjectHasNoParts() {
        #expect(MetadataJSON(entries: [:]).split(maxBytes: 428) == [])
    }
    
    @Test func readOnlyKeysMatchTheDeviceRules() {
        #expect(MetadataJSON.readOnlyKeys == ["channels", "samplerate", "format", "crc"])
    }
}
