//
//  MetadataJSON.swift
//  Krush
//
//  Created by xhiew on 19/11/26.
//

import Foundation

/// A flat JSON object of scalar values, as the device stores slot metadata.
struct MetadataJSON: Equatable {
    enum Value: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }
    
    static let readOnlyKeys: Set<String> = ["channels", "samplerate", "format", "crc"]
    
    var entries: [String: Value]
    
    var keys: [String] {
        entries.keys.sorted()
    }
    
    init(entries: [String: Value]) {
        self.entries = entries
    }
    
    /// `nil` unless `text` is a JSON object whose values are all scalars.
    init?(parsing text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return nil
        }
        var parsed: [String: Value] = [:]
        for (key, raw) in object {
            guard let value = Self.scalar(raw) else { return nil }
            parsed[key] = value
        }
        entries = parsed
    }
    
    /// Compact, keys sorted.
    var serialized: String {
        "{" + keys.map { pair($0) }.joined(separator: ",") + "}"
    }
    
    func removing(keys removed: Set<String>) -> MetadataJSON {
        MetadataJSON(entries: entries.filter { !removed.contains($0.key) })
    }
    
    func restricting(to kept: [String]) -> MetadataJSON {
        let wanted = Set(kept)
        return MetadataJSON(entries: entries.filter { wanted.contains($0.key) })
    }
    
    /// Objects of at most `maxBytes` each, that merge back into `self`. `nil` when one pair alone is too long.
    func split(maxBytes: Int) -> [String]? {
        var parts: [String] = []
        var current: [String] = []
        var currentBytes = 2
        for key in keys {
            let entry = pair(key)
            let entryBytes = entry.utf8.count
            guard entryBytes + 2 <= maxBytes else { return nil }
            let added = entryBytes + (current.isEmpty ? 0 : 1)
            if currentBytes + added > maxBytes {
                parts.append("{" + current.joined(separator: ",") + "}")
                current = []
                currentBytes = 2
            }
            currentBytes += entryBytes + (current.isEmpty ? 0 : 1)
            current.append(entry)
        }
        if !current.isEmpty {
            parts.append("{" + current.joined(separator: ",") + "}")
        }
        return parts
    }
    
    private func pair(_ key: String) -> String {
        Self.fragment(.string(key)) + ":" + Self.fragment(entries[key] ?? .null)
    }
    
    private static func scalar(_ raw: Any) -> Value? {
        if raw is NSNull {
            return .null
        }
        if let string = raw as? String {
            return .string(string)
        }
        guard let number = raw as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        return .number(number.doubleValue)
    }
    
    private static func fragment(_ value: Value) -> String {
        switch value {
        case .string(let string):
            guard let data = try? JSONSerialization.data(withJSONObject: [string], options: [.withoutEscapingSlashes]) else {
                return "\"\""
            }
            let text = String(decoding: data, as: UTF8.self)
            return String(text.dropFirst().dropLast())
        case .number(let number):
            if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                return String(Int64(number))
            }
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        }
    }
}
