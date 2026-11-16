//
//  SimJSONObjectTests.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

import Testing
@testable import KRSim

struct SimJSONObjectTests {
    @Test func parsesFlatObject() {
        #expect(SimJSONObject.parse(#"{"a":1,"b":"x"}"#) == ["a": "1", "b": "\"x\""])
    }
    
    @Test func parsesEmptyObjectAndWhitespace() {
        #expect(SimJSONObject.parse("{}") == [:])
        #expect(SimJSONObject.parse(" { \"a\" : -3.5e2 ,\n \"b\" : true , \"c\":null } ") == [
            "a": "-3.5e2", "b": "true", "c": "null"
        ])
    }
    
    @Test func keepsEscapesInRawValueAndDecodesKeys() {
        let parsed = SimJSONObject.parse(#"{"k\"q":"a\"b\\cA"}"#)
        #expect(parsed == [#"k"q"#: #""a\"b\\cA""#])
    }
    
    @Test func rejectsNestedAndMalformed() {
        #expect(SimJSONObject.parse(#"{"a":{"b":1}}"#) == nil)
        #expect(SimJSONObject.parse(#"{"a":[1]}"#) == nil)
        #expect(SimJSONObject.parse(#"{"a":1"#) == nil)
        #expect(SimJSONObject.parse(#"{"a":1} x"#) == nil)
        #expect(SimJSONObject.parse(#"{"a":"\u00zz"}"#) == nil)
        #expect(SimJSONObject.parse("") == nil)
    }
    
    @Test func serializesSortedAndCompact() {
        #expect(SimJSONObject.serialize(["b": "2", "a": "\"x\""]) == #"{"a":"x","b":2}"#)
        #expect(SimJSONObject.serialize([:]) == "{}")
    }
    
    @Test func roundTrips() {
        let object = ["name": "\"kick\"", "sound.pan": "-3"]
        #expect(SimJSONObject.parse(SimJSONObject.serialize(object)) == object)
    }
}
