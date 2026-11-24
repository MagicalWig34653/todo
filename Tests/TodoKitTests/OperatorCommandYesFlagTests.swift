import Fluent
import XCTVapor
@testable import TodoKit

/// Card 300B3A20: ConsoleKit consumes `--yes`/`-y` itself (global signature) and only sets `console.confirmOverride`,
/// so a command's own `@Flag(name: "yes")` never sees `true`. These tests run the commands through
/// `Console.run(_:with:)` - the same path `App <command> --yes` takes - instead of calling `run(using:signature:)` directly.
final class OperatorCommandYesFlagTests: XCTestCase {
    private func run(_ command: any AnyAsyncCommand, _ args: [String], app: Application) async throws {
        var context = CommandContext(console: Terminal(), input: CommandInput(arguments: ["App"] + args))
        context.application = app
        try await context.console.run(command, with: context)
    }

    private func assertConfirmationRequired(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected confirmation_required", file: file, line: line) }
        catch { XCTAssertTrue(((error as? Abort)?.reason ?? "").hasPrefix("confirmation_required"), "\(error)", file: file, line: line) }
    }

    // MARK: settings rotate-key

    func testRotateKeyAcceptsYesConsumedByConsoleKit() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        setenv("SETTINGS_ENCRYPTION_KEY", ServerSettingsTests.keyA, 1); defer { unsetenv("SETTINGS_ENCRYPTION_KEY") }
        try await run(RotateSettingsKeyCommand(), ["--yes"], app: t.app)
        try await run(RotateSettingsKeyCommand(), ["-y"], app: t.app)
    }

    func testRotateKeyWithoutYesStillNeedsConfirmation() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        setenv("SETTINGS_ENCRYPTION_KEY", ServerSettingsTests.keyA, 1); defer { unsetenv("SETTINGS_ENCRYPTION_KEY") }
        await assertConfirmationRequired { try await run(RotateSettingsKeyCommand(), [], app: t.app) }
        await assertConfirmationRequired { try await run(RotateSettingsKeyCommand(), ["--no"], app: t.app) }
    }

    // MARK: push-test

    private func pushFixture() async throws -> (t: TestApp, mock: MockAPNs, account: PushTests.Account) {
        let t = try await TestApp.make()
        let account = try await PushTests.account(t, "Anna")
        let cfg = PushTests.config()
        t.app.settings.apns = cfg
        let mock = MockAPNs()
        t.app.apnsSender = try APNsSender(config: cfg, transport: mock)
        let device = PushDevice()
        device.userID = account.id; device.platform = "ios"; device.token = "tok-yes"; device.tokenHash = "h-yes"
        device.environment = "sandbox"; device.bundleID = "de.linolaske.todo"; device.lastSeenAt = Date()
        try await device.save(on: t.app.db)
        return (t, mock, account)
    }

    func testPushTestSendsWithYesConsumedByConsoleKit() async throws {
        let f = try await pushFixture(); defer { Task { await f.t.shutdown() } }
        try await run(PushTestCommand(), [f.account.id.uuidString, "--yes"], app: f.t.app)
        XCTAssertEqual(f.mock.requests.count, 1)
    }

    func testPushTestWithoutYesSendsNothing() async throws {
        let f = try await pushFixture(); defer { Task { await f.t.shutdown() } }
        await assertConfirmationRequired { try await run(PushTestCommand(), [f.account.id.uuidString], app: f.t.app) }
        XCTAssertTrue(f.mock.requests.isEmpty)
    }
}
