//
//  SimJSONObject.swift
//  Krush
//
//  Created by xhiew on 16/11/26.
//

/// Flat JSON objects only; maps each key to the raw text of its value.
enum SimJSONObject {
    static func parse(_ text: String) -> [String: String]? {
        var parser = Parser(bytes: Array(text.utf8))
        return parser.parseDocument()
    }
    
    /// Keys sorted, compact.
    static func serialize(_ object: [String: String]) -> String {
        let members = object.keys.sorted().map { key in
            "\"" + escape(key) + "\":" + (object[key] ?? "null")
        }
        return "{" + members.joined(separator: ",") + "}"
    }
    
    private static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
    
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        
        mutating func parseDocument() -> [String: String]? {
            skipSpace()
            guard consume("{") else { return nil }
            var result: [String: String] = [:]
            skipSpace()
            if consume("}") { return finish(result) }
            while true {
                skipSpace()
                guard let key = parseString() else { return nil }
                skipSpace()
                guard consume(":") else { return nil }
                skipSpace()
                guard let value = parseValue() else { return nil }
                result[key.decoded] = value
                skipSpace()
                if consume("}") { return finish(result) }
                guard consume(",") else { return nil }
            }
        }
        
        private func finish(_ result: [String: String]) -> [String: String]? {
            var rest = self
            rest.skipSpace()
            return rest.index == bytes.count ? result : nil
        }
        
        private mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }
        
        private mutating func consume(_ character: Unicode.Scalar) -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
            index += 1
            return true
        }
        
        private mutating func parseValue() -> String? {
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "\""):
                return parseString()?.raw
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                return nil
            default:
                return parseBare()
            }
        }
        
        private mutating func parseBare() -> String? {
            for literal in ["true", "false", "null"] where bytes[index...].starts(with: Array(literal.utf8)) {
                index += literal.utf8.count
                return literal
            }
            let start = index
            while index < bytes.count, "-+.eE0123456789".utf8.contains(bytes[index]) {
                index += 1
            }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        
        /// `raw` keeps quotes and escapes; `decoded` has them resolved.
        private mutating func parseString() -> (raw: String, decoded: String)? {
            guard consume("\"") else { return nil }
            let start = index - 1
            var decoded: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return (String(decoding: bytes[start..<index], as: UTF8.self),
                            String(decoding: decoded, as: UTF8.self))
                case UInt8(ascii: "\\"):
                    guard let unescaped = parseEscape() else { return nil }
                    decoded.append(contentsOf: unescaped)
                case 0..<0x20:
                    return nil
                default:
                    decoded.append(byte)
                }
            }
            return nil
        }
        
        private mutating func parseEscape() -> [UInt8]? {
            guard index < bytes.count else { return nil }
            let code = bytes[index]
            index += 1
            switch code {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): return [code]
            case UInt8(ascii: "b"): return [0x08]
            case UInt8(ascii: "f"): return [0x0C]
            case UInt8(ascii: "n"): return [0x0A]
            case UInt8(ascii: "r"): return [0x0D]
            case UInt8(ascii: "t"): return [0x09]
            case UInt8(ascii: "u"):
                guard index + 4 <= bytes.count,
                      bytes[index..<index + 4].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
                      let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16),
                      let scalar = Unicode.Scalar(value) else { return nil }
                index += 4
                return Array(String(Character(scalar)).utf8)
            default:
                return nil
            }
        }
    }
}
