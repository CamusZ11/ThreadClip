import Foundation
import SQLite3

enum CodexReadError: LocalizedError {
    case database(String, Int32)
    case schema(String)

    var errorDescription: String? {
        switch self {
        case let .database(database, code):
            return "Could not read \(database) (SQLite code \(code))."
        case let .schema(table):
            return "The installed Codex database has an unsupported \(table) schema."
        }
    }
}

final class CodexReadOnlyDatabase {
    private let handle: OpaquePointer
    private let name: String

    init(url: URL) throws {
        name = url.lastPathComponent
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw CodexReadError.database(name, result)
        }
        sqlite3_busy_timeout(connection, 100)
        let queryOnly = sqlite3_exec(connection, "PRAGMA query_only=ON", nil, nil, nil)
        guard queryOnly == SQLITE_OK else {
            sqlite3_close(connection)
            throw CodexReadError.database(name, queryOnly)
        }
        handle = connection
    }

    deinit { sqlite3_close(handle) }

    func columns(_ table: String, required: Set<String>) throws -> Set<String> {
        let columns = Set(try rows("PRAGMA table_info(\(table))") { Self.text($0, 1) ?? "" })
        guard required.isSubset(of: columns) else {
            throw CodexReadError.schema(table)
        }
        return columns
    }

    func rows<Row>(_ sql: String, _ bindings: [String] = [], map: (OpaquePointer) -> Row) throws -> [Row] {
        var statement: OpaquePointer?
        let preparation = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard preparation == SQLITE_OK, let statement else {
            throw CodexReadError.database(name, preparation)
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let result = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            guard result == SQLITE_OK else { throw CodexReadError.database(name, result) }
        }

        var rows: [Row] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            rows.append(map(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw CodexReadError.database(name, result) }
        return rows
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    static func timestamp(_ row: OpaquePointer, _ column: Int32, scale: Double = 1) -> Date? {
        guard sqlite3_column_type(row, column) != SQLITE_NULL else { return nil }
        let seconds = sqlite3_column_double(row, column) / scale
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
