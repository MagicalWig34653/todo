import Vapor

/// Small builders for tool input schemas. Every field carries a description (enforced by a test).
enum Schema {
    static func string(_ description: String, values: [String]? = nil, maxLength: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { o["enum"] = .strings(values) }
        if let maxLength { o["maxLength"] = .number(Double(maxLength)) }
        return .object(o)
    }
    static func uuid(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "format": .string("uuid"), "description": .string(description)])
    }
    static func integer(_ description: String, min: Int? = nil, max: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let min { o["minimum"] = .number(Double(min)) }
        if let max { o["maximum"] = .number(Double(max)) }
        return .object(o)
    }
    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
    static func nullable(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .array([.string(type), .string("null")]), "description": .string(description)])
    }
    static func stringArray(_ description: String, maxItems: Int) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "maxItems": .number(Double(maxItems)), "description": .string(description)])
    }
}
