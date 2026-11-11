import Foundation

/// 노드·엣지의 자유 형식 속성(props)을 담는 JSON 값.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            var dict: [String: JSONValue] = [:]
            for key in keyed.allKeys {
                dict[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(dict)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(JSONValue.self)) }
            self = .array(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let b = try? single.decode(Bool.self) { self = .bool(b); return }
        if let d = try? single.decode(Double.self) { self = .number(d); return }
        self = .string(try single.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        case .number(let d):
            var c = encoder.singleValueContainer()
            if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { try c.encode(Int64(d)) } else { try c.encode(d) }
        case .bool(let b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .array(let items):
            var c = encoder.unkeyedContainer()
            for item in items { try c.encode(item) }
        case .object(let dict):
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in dict { try c.encode(v, forKey: AnyKey(k)) }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    // MARK: 접근 도우미

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    // MARK: 직렬화

    public static func encodeObject(_ props: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(props)),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    public static func decodeObject(_ text: String?) -> [String: JSONValue] {
        guard let text, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let dict) = value else { return [:] }
        return dict
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
