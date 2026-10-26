import Vapor

indirect enum JSONValue: Content, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var isNull: Bool { if case .null = self { return true }; return false }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    static func strings(_ values: [String]) -> JSONValue { .array(values.map(Self.string)) }
    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}
