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
}
