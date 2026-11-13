import XCTest
@testable import TodoKit

/// Live view per card (ADR 0031): the secrets filter runs before anything is stored.
final class SecretFilterTests: XCTestCase {
    private let mask = SecretFilter.mask

    /// (name, input, secret fragment that must not survive)
    private let positives: [(String, String, String)] = [
        ("bearer header value", "curl -H 'Authorization: Bearer abcDEF1234567890xyz' https://x.example", "abcDEF1234567890xyz"),
        ("bearer in prose", "sent Bearer ya29.A0ARrdaM-token_value-123 to the API", "ya29.A0ARrdaM-token_value-123"),
        ("authorization basic", "Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpwYXNzd29yZA"),
        ("openai style key", "using sk-proj-AbCdEf0123456789AbCdEf0123456789 now", "AbCdEf0123456789AbCdEf0123456789"),
        ("anthropic style key", "key sk-ant-api03-Zm9vYmFyYmF6cXV1eDEyMzQ1Njc4OQ ready", "Zm9vYmFyYmF6cXV1eDEyMzQ1Njc4OQ"),
        ("github pat", "token ghp_1234567890abcdefghijklmnopqrstuvwxyzAB used", "ghp_1234567890abcdefghijklmnopqrstuvwxyzAB"),
        ("github fine grained", "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuv end", "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuv"),
        ("aws access key", "AWS key AKIAIOSFODNN7EXAMPLE found", "AKIAIOSFODNN7EXAMPLE"),
        ("slack token", "\("xo" + "xb")-123456789012-abcdefghijklmnop in env", "\("xo" + "xb")-123456789012-abcdefghijklmnop"),
        ("google api key", "AIzaSyA1234567890abcdefghijklmnopqrstuvw used", "AIzaSyA1234567890abcdefghijklmnopqrstuvw"),
        ("jwt", "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r found", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"),
        ("private key block", "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAx1y2z3\n-----END RSA PRIVATE KEY----- done", "MIIEowIBAAKCAQEAx1y2z3"),
        ("truncated private key block", "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQ", "MIIEvQIBADANBgkqhkiG9w0BAQ"),
        ("password assignment", "set password=hunter2 in the config", "hunter2"),
        ("password colon", "PASSWORD: s3cr3tValue!", "s3cr3tValue!"),
        ("secret env", "export CLIENT_SECRET=abc123def456 && run", "abc123def456"),
        ("token json", "{\"access_token\": \"abc.def.ghi\", \"ok\": true}", "abc.def.ghi"),
        ("quoted value with spaces", "api_key = 'my secret value'", "my secret value"),
        ("api key flag style", "apikey=ZZZ999yyy", "ZZZ999yyy"),
        ("url credentials", "git clone https://lino:p4ssw0rd@github.com/org/repo.git", "p4ssw0rd"),
        ("long hex", "key 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 stored", "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"),
        ("long base64", "blob dGhpcyBpcyBhIHZlcnkgbG9uZyBiYXNlNjQgc2VjcmV0IHZhbHVlMTIz stored", "dGhpcyBpcyBhIHZlcnkgbG9uZyBiYXNlNjQgc2VjcmV0IHZhbHVlMTIz"),
        ("german password", "Das Passwort: Geheim123x gesetzt", "Geheim123x"),
        ("german kennwort", "kennwort=Sommer2026! eingetragen", "Sommer2026!"),
        ("german zugangsdaten", "Zugangsdaten: lino/abc987 notiert", "abc987"),
        ("german schluessel", "Schlüssel = Qwertz77 benutzt", "Qwertz77"),
        ("cli flag long", "mysql --password hunter2 -h db", "hunter2"),
        ("cli flag equals", "tool --token=abcd1234 run", "abcd1234"),
        ("cli flag short", "mysql -u root -phunter2 db", "hunter2"),
        ("curl user", "curl -u admin:s3cretpw https://x.example", "s3cretpw"),
        ("cookie header", "Cookie: session=abc123def; theme=dark", "abc123def"),
        ("set-cookie", "Set-Cookie: sid=zzz999; Path=/", "zzz999"),
        ("db pass env", "DB_PASS=Tr0ub4dor run", "Tr0ub4dor"),
        ("auth env", "AUTH=xyz789abc go", "xyz789abc"),
        ("key env", "KEY=k3y5ecret1 go", "k3y5ecret1"),
        ("escaped json", "body {\\\"password\\\":\\\"hunter2x\\\"} sent", "hunter2x"),
        ("url encoded", "q=password%3Dhunter2x&a=1", "hunter2x"),
        ("fullwidth colon", "password：hunter2x", "hunter2x"),
        ("zero width in key", "pass\u{200B}word=hunter2x", "hunter2x"),
        ("gitlab pat", "glpat-abcDEF123456789xyzQ used", "glpat-abcDEF123456789xyzQ"),
        ("stripe live", "sk_live_51HabcDEFgh12 used", "sk_live_51HabcDEFgh12"),
        ("stripe test", "sk_test_4eC39HqLyjWDarjt used", "sk_test_4eC39HqLyjWDarjt"),
        ("url password with at", "git clone https://lino:p@ss@github.com/o/r.git", "p@ss"),
        ("url password with slash", "git clone https://lino:pa/ss@github.com/o/r.git", "pa/ss"),
        ("random token like ours", "token Qm3x9Z_k-L2vN8pR4sT7uW1yA5cE0gI6hJdFbXoMeQw leaked", "Qm3x9Z_k-L2vN8pR4sT7uW1yA5cE0gI6hJdFbXoMeQw"),
    ]

    private let negatives: [(String, String)] = [
        ("plain progress", "Login screen done, token refresh next"),
        ("prose about passwords", "password reset flow implemented and tested"),
        ("prose about tokens", "reading the token from the environment works"),
        ("git commit sha", "merged commit 4111567c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f60 into main"),
        ("short sha", "fixed in 4111567"),
        ("file path", "editing Sources/TodoKit/LiveSession/LiveSessionService.swift and Tests/TodoKitTests/LiveSessionTests.swift"),
        ("long kebab branch", "branch agent/live-ansicht-backend-with-a-rather-long-descriptive-name"),
        ("url without credentials", "opened https://example.com/path?x=1 in the browser"),
        ("email-like url at sign", "see https://example.com/@user/profile for details"),
        ("sk in prose", "the task-list skeleton is ready, sk-short"),
        ("german text", "Tests laufen, nächster Schritt: Migration prüfen (Token-Ablauf bleibt)"),
        ("numbers", "535 Tests, 0 Fehlschläge, Exit 0"),
        ("empty-ish", "ok"),
        ("url with port and at path", "see https://example.com:8080/@user/profile ok"),
        ("german prose", "Das Passwort-Reset ist fertig und das Kennwortfeld getestet"),
        ("key in prose", "the key idea is simple"),
        ("flag without secret", "run --verbose -p 8080 now"),
    ]

    func testPositivesAreMaskedAndSecretNeverSurvives() {
        for (name, input, secret) in positives {
            let out = SecretFilter.redact(input)
            XCTAssertTrue(out.didRedact, name)
            XCTAssertTrue(out.text.contains(mask), "\(name): \(out.text)")
            if !secret.isEmpty { XCTAssertFalse(out.text.contains(secret), "\(name): \(out.text)") }
        }
    }

    func testNegativesStayUntouched() {
        for (name, input) in negatives {
            let out = SecretFilter.redact(input)
            XCTAssertFalse(out.didRedact, "\(name): \(out.text)")
            XCTAssertEqual(out.text, input, name)
        }
    }

    func testHugeInputIsBoundedBeforeTheRegexRules() {
        let started = Date()
        let out = SecretFilter.redact(String(repeating: "password", count: 50_000) + " tail")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertLessThanOrEqual(out.text.unicodeScalars.count, SecretFilter.maxInputScalars + 64)
    }

    func testKeyNamesStayReadableAndFilterIsIdempotent() {
        XCTAssertEqual(SecretFilter.redact("password=hunter2 and more").text, "password=\(mask) and more")
        XCTAssertEqual(SecretFilter.redact("Authorization: Bearer abcdefgh12345678").text, "Authorization: \(mask)")
        XCTAssertEqual(SecretFilter.redact("https://u:p@host/x").text, "https://\(mask)@host/x")
        for (_, input, _) in positives {
            let once = SecretFilter.redact(input).text
            XCTAssertEqual(SecretFilter.redact(once).text, once)
        }
    }
}
