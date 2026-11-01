import Foundation
import XCTVapor
@testable import TodoKit

final class ContractTests: XCTestCase {
    private struct Operation: Hashable, CustomStringConvertible {
        let method: String
        let path: String
        var description: String { "\(method) \(path)" }
    }

    private enum ContractError: Error {
        case invalidRouteIndex(String)
    }

    /// Minimal parser for this contract's block-style paths/operations index, not general YAML.
    /// Schema parsing and OpenAPI validation belong to the OpenAPI linter. Reject unsupported index
    /// syntax rather than silently skipping it; no YAML dependency is needed for route coverage.
    private func operations(in yaml: String) throws -> Set<Operation> {
        let methods: Set<String> = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]
        let pathFields: Set<String> = ["parameters", "summary", "description", "servers"]
        var inPaths = false
        var foundPaths = false
        var path: String?
        var result = Set<Operation>()
        for raw in yaml.components(separatedBy: .newlines) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if raw == "paths:" {
                guard !foundPaths else { throw ContractError.invalidRouteIndex(raw) }
                inPaths = true
                foundPaths = true
                continue
            }
            guard inPaths else { continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            if indent == 0 { inPaths = false; continue }
            if indent == 2 {
                guard text.hasPrefix("/"), text.hasSuffix(":"), !text.contains(" ") else {
                    throw ContractError.invalidRouteIndex(raw)
                }
                path = String(text.dropLast())
            } else if indent == 4 {
                guard let path, let colon = text.firstIndex(of: ":") else {
                    throw ContractError.invalidRouteIndex(raw)
                }
                let key = String(text[..<colon])
                if methods.contains(key) {
                    guard text == "\(key):", result.insert(Operation(method: key.uppercased(), path: path)).inserted else {
                        throw ContractError.invalidRouteIndex(raw)
                    }
                } else if !pathFields.contains(key), !key.hasPrefix("x-") {
                    throw ContractError.invalidRouteIndex(raw)
                }
            } else if indent < 4 {
                throw ContractError.invalidRouteIndex(raw)
            }
        }
        guard foundPaths, !result.isEmpty else { throw ContractError.invalidRouteIndex("Missing operations") }
        return result
    }

    private func operations(in routes: Routes) -> Set<Operation> {
        Set(routes.all.map { route in
            let path = route.path.map { component -> String in
                switch component {
                case .constant(let value): return value
                case .parameter(let name): return "{\(name)}"
                case .anything: return "*"
                case .catchall: return "**"
                }
            }.joined(separator: "/")
            return Operation(method: route.method.rawValue, path: "/" + path)
        })
    }

    func testContractMatchesRegisteredRoutes() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let yaml = try String(contentsOf: root.appendingPathComponent("contracts/openapi.yaml"), encoding: .utf8)
        let documented = try operations(in: yaml)
        let app = try await Application.make(.testing)
        do {
            try routes(app)
            let registered = operations(in: app.routes)
            XCTAssertTrue(documented.isSubset(of: registered),
                          "Documented operations missing in router: \(documented.subtracting(registered))")

            // Discover controller ownership by booting the actual collections, so a newly added
            // Auth/Planning path cannot escape coverage through a hardcoded prefix allowlist.
            let ownedRoutes = Routes()
            try AuthController().boot(routes: ownedRoutes)
            try PlanningController().boot(routes: ownedRoutes)
            let owned = operations(in: ownedRoutes)
            let documentedPaths = Set(documented.map(\.path))
            let scoped = registered.filter {
                $0.path.hasPrefix("/v1/") && (owned.contains($0) || documentedPaths.contains($0.path))
            }
            XCTAssertTrue(scoped.isSubset(of: documented),
                          "Router operations missing in contract: \(scoped.subtracting(documented))")
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    func testRouteIndexParserRejectsMissingAndDuplicateOperations() throws {
        XCTAssertThrowsError(try operations(in: "openapi: 3.1.0\npaths: {}"))
        XCTAssertThrowsError(try operations(in: "paths:\n  /v1/me:\n    get:\n    get:"))
        XCTAssertThrowsError(try operations(in: "paths:\n  /v1/me: {get: {}}"))
        let parsed = try operations(in: "paths:\n  /v1/me:\n    get:\n      summary: Account\ncomponents:\n  schemas: {}")
        XCTAssertEqual(parsed, [Operation(method: "GET", path: "/v1/me")])
    }

    /// Top-level object schemas (components/schemas, 4-space indent) with block-style `required` and `properties`.
    /// Returns schema name -> (required, property names). Minimal parser, not general YAML.
    private func schemas(in yaml: String) -> [String: (required: Set<String>, properties: Set<String>)] {
        var result: [String: (required: Set<String>, properties: Set<String>)] = [:]
        var inSchemas = false
        var name: String?
        var section = ""
        var required = Set<String>(), props = Set<String>()
        func flush() { if let name { result[name] = (required, props) } }
        for raw in yaml.components(separatedBy: .newlines) {
            if raw == "components:" || raw == "paths:" { flush(); name = nil; inSchemas = false }
            if raw == "  schemas:" { inSchemas = true; continue }
            guard inSchemas else { continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if indent <= 2 { flush(); name = nil; inSchemas = false; continue }
            if indent == 4, text.hasSuffix(":") {
                flush(); name = String(text.dropLast()); section = ""; required = []; props = []
            } else if indent == 6 {
                section = text.hasPrefix("required:") ? "required" : (text == "properties:" ? "properties" : "")
                if section == "required", let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]") {
                    required.formUnion(text[text.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    section = ""
                }
            } else if indent == 8, section == "required", text.hasPrefix("- ") {
                required.insert(String(text.dropFirst(2)))
            } else if indent == 8, section == "properties", let colon = text.firstIndex(of: ":") {
                props.insert(String(text[..<colon]))
            }
        }
        flush()
        return result
    }

    private func contractYAML() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("contracts/openapi.yaml"), encoding: .utf8)
    }

    /// Every required property of a schema must be declared in that schema (catches a property filed under the wrong schema).
    func testRequiredPropertiesAreDeclaredInTheirOwnSchema() throws {
        let all = schemas(in: try contractYAML())
        XCTAssertNotNil(all["Invitation"]); XCTAssertNotNil(all["InvitationSummary"]); XCTAssertNotNil(all["Session"])
        for (name, schema) in all where !schema.properties.isEmpty {
            XCTAssertTrue(schema.required.isSubset(of: schema.properties), "\(name): required but undeclared \(schema.required.subtracting(schema.properties))")
        }
        XCTAssertFalse(all["Session"]!.properties.contains("id"), "invitation id belongs to Invitation, not Session")
    }

    /// The real invitation responses carry exactly the documented properties.
    func testInvitationResponsesMatchTheContract() async throws {
        let all = schemas(in: try contractYAML())
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let created = try await t.json(.POST, "/v1/invitations", token: a.session)
        XCTAssertEqual(Set(created.body?.keys.map { $0 } ?? []), all["Invitation"]?.properties)
        let list = try await t.json(.GET, "/v1/invitations", token: a.session)
        let row = Set(try XCTUnwrap(list.list?.first).keys)
        XCTAssertTrue(all["InvitationSummary"]!.required.isSubset(of: row))
        XCTAssertTrue(row.isSubset(of: all["InvitationSummary"]!.properties))
    }
}
