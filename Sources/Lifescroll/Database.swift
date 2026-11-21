import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBValue: Equatable {
  case int(Int64)
  case double(Double)
  case text(String)
  case null

  static func date(_ date: Date?) -> DBValue {
    date.map { .double($0.timeIntervalSince1970) } ?? .null
  }

  static func bool(_ flag: Bool) -> DBValue { .int(flag ? 1 : 0) }
}

struct DBRow {
  let values: [String: DBValue]

  func string(_ key: String) -> String {
    if case .text(let value)? = values[key] { return value }
    return ""
  }

  /// Nil for a NULL column, where `string` would give an empty string.
  func optionalString(_ key: String) -> String? {
    if case .text(let value)? = values[key] { return value }
    return nil
  }

  func double(_ key: String) -> Double {
    switch values[key] {
    case .double(let value)?: return value
    case .int(let value)?: return Double(value)
    default: return 0
    }
  }

  func int(_ key: String) -> Int { Int(double(key)) }

  func int64(_ key: String) -> Int64 {
    if case .int(let value)? = values[key] { return value }
    return Int64(double(key))
  }

  func date(_ key: String) -> Date? {
    switch values[key] {
    case .double(let value)?: return Date(timeIntervalSince1970: value)
    case .int(let value)?: return Date(timeIntervalSince1970: Double(value))
    default: return nil
    }
  }
}

struct DBError: LocalizedError {
  let message: String
  var errorDescription: String? { "Database error: \(message)" }
}

/// A small serialised wrapper around SQLite. Every call runs on one queue, so it is safe to use
/// from the main actor and from the analyzer at the same time.
final class Database: @unchecked Sendable {
  private var handle: OpaquePointer?
  private let queue = DispatchQueue(label: "lifescroll.database")

  init(path: String) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
      sqlite3_close(handle)
      throw DBError(message: message)
    }
    sqlite3_busy_timeout(handle, 2000)
    _ = try? query("PRAGMA journal_mode=WAL")
    // Overwrite deleted content with zeros. Screen text passes through this file, and without this
    // "deleted" rows stay readable in the file's free space.
    _ = try? query("PRAGMA secure_delete=ON")
  }

  deinit { sqlite3_close(handle) }

  /// Runs one or more statements with no parameters. Used for the schema.
  func exec(_ sql: String) throws {
    try queue.sync {
      var error: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(error)
        throw DBError(message: message)
      }
    }
  }

  /// Runs one statement and returns the last inserted row id.
  @discardableResult
  func execute(_ sql: String, _ params: [DBValue] = []) throws -> Int64 {
    try queue.sync {
      _ = try run(sql, params)
      return sqlite3_last_insert_rowid(handle)
    }
  }

  func query(_ sql: String, _ params: [DBValue] = []) throws -> [DBRow] {
    try queue.sync { try run(sql, params) }
  }

  private func run(_ sql: String, _ params: [DBValue]) throws -> [DBRow] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw DBError(message: String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }

    for (offset, param) in params.enumerated() {
      let index = Int32(offset + 1)
      switch param {
      case .int(let value): sqlite3_bind_int64(statement, index, value)
      case .double(let value): sqlite3_bind_double(statement, index, value)
      case .text(let value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
      case .null: sqlite3_bind_null(statement, index)
      }
    }

    var rows: [DBRow] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else {
        throw DBError(message: String(cString: sqlite3_errmsg(handle)))
      }
      var values: [String: DBValue] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
          values[name] = .text(String(cString: sqlite3_column_text(statement, column)))
        default: values[name] = .null
        }
      }
      rows.append(DBRow(values: values))
    }
    return rows
  }
}
