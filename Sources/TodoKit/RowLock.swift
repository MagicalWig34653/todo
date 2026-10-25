import Foundation
import Fluent
import FluentSQL
import SQLKit

/// Pessimistic row lock (`SELECT … FOR UPDATE`) for read-modify-write inside a transaction.
/// MariaDB only; SQLite (tests) serialises writers anyway and has no row locks.
func lockRow(table: String, id: UUID, on db: any Database) async throws {
    guard let sql = db as? any SQLDatabase, sql.dialect.name != "sqlite" else { return }
    _ = try await sql.raw("SELECT id FROM \(unsafeRaw: table) WHERE id = \(bind: id) FOR UPDATE").all()
}
