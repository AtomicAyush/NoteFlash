import Foundation

/// A tiny Encodable JSON tree, used to write JSON Schemas inline.
nonisolated indirect enum JSONValue: Encodable, Sendable,
    ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case string(String)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value): try value.encode(to: encoder)
        case .bool(let value): try value.encode(to: encoder)
        case .array(let value): try value.encode(to: encoder)
        case .object(let value): try value.encode(to: encoder)
        }
    }

    /// `{"type": "object", ...}` with every property required, as structured outputs expect.
    static func strictObject(_ properties: [String: JSONValue]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map { .string($0) }),
            "additionalProperties": false,
        ]
    }

    static func arrayOf(_ items: JSONValue) -> JSONValue {
        ["type": "array", "items": items]
    }

    static let stringType: JSONValue = ["type": "string"]
}
