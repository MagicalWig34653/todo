import Foundation
import XCTest
@testable import TodoKit

/// Keeps `deploy/swarm/config-registry.tsv` (read by `deploy/swarm/settings.sh`) in sync with `SettingsRegistry.definitions`
/// and checks that the hand-maintained `deploy/swarm/config-extra.tsv`, `stack.env.example` and the stack files agree.
/// Regenerate the table with: UPDATE_CONFIG_TSV=1 swift test --filter SettingsRegistryTSV
final class SettingsRegistryTSVTests: XCTestCase {
    static let columns = ["key", "group", "type", "default", "unit", "min", "max", "choices", "apply", "secret", "summary"]
    static let baseTypes: Set<String> = ["int", "number", "bool", "choice", "secret", "text"]
    /// Variables that deploy scripts compute and hand to the stack files; they are not meant for the env file.
    static let computed: Set<String> = ["BACKEND_PINNED_CONSTRAINT", "BACKEND_PINNED_EFFECTIVE_REPLICAS"]

    static func root() -> URL {
        // .../Tests/TodoKitTests/SettingsRegistryTSVTests.swift -> repository root
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func swarmDirectory() -> URL { root().appendingPathComponent("deploy/swarm") }

    static func field(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// Value rule for settings.sh (`text:<rule>`); everything not listed here is free text up to its maximum length.
    static let textRules: [String: String] = [
        "mail.smtpHost": "hostaddr",
        "mail.from": "mailbox",
        "push.keyId": "appleid",
        "push.teamId": "appleid",
        "push.topics": "list",
        "attachments.s3Endpoint": "httpurl",
        "apple.appIds": "list",
    ]

    static func row(_ d: SettingDefinition) -> String {
        var type = "", lo = "", hi = "", choices = ""
        switch d.type {
        case .bool: type = "bool"
        case .int:
            type = "int"; lo = String(d.min ?? 0); hi = String(d.max ?? Int.max)
            XCTAssertNotNil(d.min, "\(d.key) needs a minimum for settings.sh"); XCTAssertNotNil(d.max, "\(d.key) needs a maximum for settings.sh")
        case .enumeration: type = "choice"; choices = (d.options ?? []).joined(separator: "|")
        case .string, .stringList, .text:
            type = d.secret ? "secret" : "text:" + (textRules[d.key] ?? "free")
            if !d.secret { hi = String(d.maxLength) }
            // An empty value is allowed whenever the setting has no default (a variable left empty counts as not set).
            if !d.secret, d.defaultValue == nil { type += "?" }
        }
        if d.secret { XCTAssertNil(d.defaultValue, "\(d.key): a secret must not export a default") }
        let category = SettingsRegistry.categories.first { $0.id == d.category }?.label ?? d.category
        let summary = "\(d.label): \(d.help) (PWA: \(d.key))"
        let cells = [d.env, category, type, d.secret ? "" : (d.defaultValue ?? ""), "", lo, hi, choices,
                     d.hotReload ? "live" : "restart", d.secret ? "1" : "0", summary]
        return cells.map(field).joined(separator: "\t")
    }

    static func generate() -> String {
        (["#" + columns.joined(separator: "\t")] + SettingsRegistry.definitions.map(row)).joined(separator: "\n") + "\n"
    }

    /// Non-comment rows of a table as cells.
    static func rows(of file: String) throws -> [[String]] {
        let text = try String(contentsOf: swarmDirectory().appendingPathComponent(file), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    func testTableMatchesRegistry() throws {
        let file = Self.swarmDirectory().appendingPathComponent("config-registry.tsv")
        let expected = Self.generate()
        if ProcessInfo.processInfo.environment["UPDATE_CONFIG_TSV"] == "1" {
            try expected.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let actual = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertEqual(actual, expected, """
            deploy/swarm/config-registry.tsv does not match SettingsRegistry.definitions.
            Regenerate: UPDATE_CONFIG_TSV=1 swift test --filter SettingsRegistryTSV
            and commit the file together with the code.
            """)
    }

    func testRegistrySecretsExportNoValue() throws {
        let secrets = SettingsRegistry.definitions.filter(\.secret)
        XCTAssertFalse(secrets.isEmpty)
        let rows = try Self.rows(of: "config-registry.tsv")
        for s in secrets {
            guard let r = rows.first(where: { $0[0] == s.env }) else { XCTFail("\(s.env) missing"); continue }
            XCTAssertEqual(r[2], "secret"); XCTAssertEqual(r[3], ""); XCTAssertEqual(r[9], "1")
        }
    }

    func testExtraTableIsWellFormedAndDisjoint() throws {
        let rows = try Self.rows(of: "config-extra.tsv")
        XCTAssertFalse(rows.isEmpty)
        let registry = Set(SettingsRegistry.definitions.map(\.env))
        var seen = Set<String>()
        for cells in rows {
            XCTAssertEqual(cells.count, Self.columns.count, "config-extra.tsv: \(cells.first ?? "?") has \(cells.count) columns")
            guard cells.count == Self.columns.count else { continue }
            let key = cells[0], base = cells[2].split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            XCTAssertFalse(registry.contains(key), "\(key) is in the registry already, not in config-extra.tsv")
            XCTAssertTrue(seen.insert(key).inserted, "\(key) twice in config-extra.tsv")
            XCTAssertTrue(Self.baseTypes.contains(base), "\(key): type \(cells[2])")
            XCTAssertEqual(cells[8], "envOnly", "\(key): apply \(cells[8])")
            XCTAssertTrue(["0", "1"].contains(cells[9]), "\(key): secret \(cells[9])")
            if base == "int" { XCTAssertFalse(cells[5].isEmpty || cells[6].isEmpty, "\(key): int needs min and max") }
            if base == "choice" { XCTAssertFalse(cells[7].isEmpty, "\(key): choice needs choices") }
            if cells[9] == "1" { XCTAssertEqual(cells[3], "", "\(key): a secret must not carry a default") }
        }
    }

    /// Every variable of stack.env.example (active or commented) is known to settings.sh, and no secret value is active there.
    func testTemplateOnlyNamesKnownVariablesAndNoSecretValues() throws {
        let known = Set(try Self.rows(of: "config-registry.tsv").map { $0[0] } + Self.rows(of: "config-extra.tsv").map { $0[0] })
        let secrets = Set(try (Self.rows(of: "config-registry.tsv") + Self.rows(of: "config-extra.tsv")).filter { $0[9] == "1" }.map { $0[0] })
        let text = try String(contentsOf: Self.swarmDirectory().appendingPathComponent("stack.env.example"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: "^(#\\s?)?([A-Z][A-Z0-9_]*)=", options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        var count = 0
        for m in pattern.matches(in: text, range: range) {
            let name = String(text[Range(m.range(at: 2), in: text)!]); count += 1
            XCTAssertTrue(known.contains(name), "stack.env.example names \(name), which is in neither config-registry.tsv nor config-extra.tsv")
            if m.range(at: 1).location == NSNotFound { XCTAssertFalse(secrets.contains(name), "\(name) is a secret and must not be active in the template") }
        }
        XCTAssertGreaterThan(count, 10)
    }

    /// Every ${VARIABLE} of the stack files can be set through settings.sh.
    func testStackFileVariablesAreKnown() throws {
        let known = Set(try Self.rows(of: "config-registry.tsv").map { $0[0] } + Self.rows(of: "config-extra.tsv").map { $0[0] })
        let dir = Self.swarmDirectory()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("stack.") && $0.hasSuffix(".yaml") }
        XCTAssertGreaterThan(files.count, 3)
        let pattern = try NSRegularExpression(pattern: "\\$\\{([A-Z][A-Z0-9_]*)")
        for file in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                let s = String(line)
                for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    let name = String(s[Range(m.range(at: 1), in: s)!])
                    XCTAssertTrue(known.contains(name) || Self.computed.contains(name), "\(file) uses ${\(name)}, unknown to settings.sh (add it to config-extra.tsv)")
                }
            }
        }
    }
}
