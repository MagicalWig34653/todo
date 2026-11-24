import FluentKit
import FluentSQL
import FluentSQLiteDriver
import Logging
import NIOConcurrencyHelpers
import NIOCore
import SQLKit
import SQLiteKit

// SQLite write contention (card 3C2E7F9D). The pool keeps one connection per event loop, and request handlers,
// webhook, mail and push workers and maintenance write from different loops, so two writers regularly meet.
//
// Two things went wrong with the stock fluent-sqlite-driver:
// 1. sqlite-nio installs a busy handler that answers "retry" without ever sleeping or giving up. A waiting writer
//    burns a thread of the shared thread pool; enough of them starve the thread that would commit the lock holder.
//    `PRAGMA busy_timeout` replaces that handler with one that sleeps and fails after a bounded time.
// 2. Fluent opens transactions with a deferred `BEGIN`. A transaction that reads first and writes later holds a
//    read lock when it asks for the write lock; SQLite then never invokes any busy handler (waiting could
//    deadlock) and fails at once with SQLITE_BUSY, the "busy: database is locked" behind the HTTP 500s. A
//    transaction that takes the write lock up front (`BEGIN IMMEDIATE`) just waits its turn.

/// Upper bound a SQLite connection waits for a lock held by another connection.
let sqliteBusyTimeoutMilliseconds = 5_000

/// Wraps the configuration of the stock SQLite driver; used only for the SQLite pool, MariaDB is untouched.
struct WriteLockingSQLiteConfiguration: DatabaseConfiguration {
    var base: any DatabaseConfiguration

    var middleware: [any AnyModelMiddleware] {
        get { base.middleware }
        set { base.middleware = newValue }
    }

    func makeDriver(for databases: Databases) -> any DatabaseDriver {
        WriteLockingSQLiteDriver(base: base.makeDriver(for: databases))
    }
}

typealias SQLiteFluentBackend = Database & SQLDatabase & SQLiteDatabase

struct WriteLockingSQLiteDriver: DatabaseDriver {
    let base: any DatabaseDriver
    /// Event loops whose pooled connection already received the busy timeout.
    private let armedLoops = NIOLockedValueBox(Set<ObjectIdentifier>())

    init(base: any DatabaseDriver) {
        self.base = base
    }

    func makeDatabase(with context: DatabaseContext) -> any Database {
        let database = base.makeDatabase(with: context)
        guard let backend = database as? any SQLiteFluentBackend else { return database }
        armBusyTimeout(backend, on: context.eventLoop)
        return WriteLockingSQLiteDatabase(base: backend, inTransaction: false)
    }

    /// The pool holds at most one connection per loop and serves requests in order, so the first request queued
    /// for a loop runs before anything that is queued later. A connection the pool has to reopen later (it
    /// discards closed ones) starts without the setting; SQLite errors do not close a connection.
    private func armBusyTimeout(_ backend: any SQLiteFluentBackend, on eventLoop: any EventLoop) {
        let first = armedLoops.withLockedValue { $0.insert(ObjectIdentifier(eventLoop)).inserted }
        guard first else { return }
        let logger = backend.context.logger
        backend.query("PRAGMA busy_timeout = \(sqliteBusyTimeoutMilliseconds)").whenFailure { error in
            logger.warning("Could not set the SQLite busy timeout: \(error)")
        }
    }

    func shutdown() { base.shutdown() }
    func shutdownAsync() async { await base.shutdownAsync() }
}

/// Forwards everything to the stock SQLite database, except that a top-level transaction starts with
/// `BEGIN IMMEDIATE`. Nested `transaction` calls join the open one, as in the stock driver.
struct WriteLockingSQLiteDatabase: Database, SQLDatabase, SQLiteDatabase {
    let base: any SQLiteFluentBackend
    let inTransaction: Bool

    // Database

    var context: DatabaseContext { base.context }

    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<Void> {
        base.execute(query: query, onOutput: onOutput)
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { base.execute(schema: schema) }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { base.execute(enum: `enum`) }

    func withConnection<T: Sendable>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let inTransaction = inTransaction
        return base.withConnection { (connection: any Database) -> EventLoopFuture<T> in
            guard let backend = connection as? any SQLiteFluentBackend else { return closure(connection) }
            return closure(WriteLockingSQLiteDatabase(base: backend, inTransaction: inTransaction))
        }
    }

    func transaction<T: Sendable>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        if inTransaction { return closure(self) }
        return base.withConnection { (connection: any Database) -> EventLoopFuture<T> in
            guard let backend = connection as? any SQLiteFluentBackend else { return connection.transaction(closure) }
            let scoped = WriteLockingSQLiteDatabase(base: backend, inTransaction: true)
            return scoped.raw("BEGIN IMMEDIATE TRANSACTION").run().flatMap {
                closure(scoped)
                    .flatMap { value in scoped.raw("COMMIT TRANSACTION").run().map { value } }
                    .flatMapError { error in
                        scoped.raw("ROLLBACK TRANSACTION").run()
                            .recover { _ in () }
                            .flatMapThrowing { throw error }
                    }
            }
        }
    }

    // SQLDatabase

    var dialect: any SQLDialect { base.dialect }
    var version: (any SQLDatabaseReportedVersion)? { base.version }
    var queryLogLevel: Logger.Level? { base.queryLogLevel }

    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        base.execute(sql: query, onRow)
    }

    func withSession<R>(_ closure: @escaping @Sendable (any SQLDatabase) async throws -> R) async throws -> R {
        try await base.withSession(closure)
    }

    // SQLiteDatabase

    func query(_ query: String, _ binds: [SQLiteData], logger: Logger, _ onRow: @escaping @Sendable (SQLiteRow) -> Void) -> EventLoopFuture<Void> {
        base.query(query, binds, logger: logger, onRow)
    }

    func withConnection<T>(_ closure: @escaping @Sendable (SQLiteConnection) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        base.withConnection(closure)
    }
}
