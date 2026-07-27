import Foundation
import SQLite3
import os

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func text(_ index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }

    func int(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }
}

final class SQLiteDB {
    let path: String

    private var handle: OpaquePointer?
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    init?(url: URL, label: String, busyTimeout: Int32 = 5_000) {
        path = url.path
        queue = DispatchQueue(label: label, qos: .utility)
        queue.setSpecific(key: queueKey, value: 1)

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.search.error("sqlite directory failed path=\(directory.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }

        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &raw, flags, nil)
        guard status == SQLITE_OK, let opened = raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            Log.search.error("sqlite open failed path=\(url.path, privacy: .public) status=\(status, privacy: .public) error=\(message, privacy: .public)")
            if let raw = raw { sqlite3_close_v2(raw) }
            return nil
        }

        handle = opened
        sqlite3_busy_timeout(opened, busyTimeout)

        guard execute("PRAGMA journal_mode=WAL"), execute("PRAGMA synchronous=NORMAL") else {
            Log.search.error("sqlite pragma failed path=\(url.path, privacy: .public)")
            sqlite3_close_v2(opened)
            handle = nil
            return nil
        }

        Log.search.info("sqlite opened path=\(url.path, privacy: .public) busyTimeout=\(busyTimeout, privacy: .public)")
    }

    deinit {
        guard let handle = handle else { return }
        sqlite3_close_v2(handle)
        Log.search.info("sqlite closed path=\(self.path, privacy: .public)")
    }

    func perform(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }

    @discardableResult
    func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    @discardableResult
    func execute(_ sql: String) -> Bool {
        sync {
            guard let handle = self.handle else {
                Log.search.error("sqlite exec on closed handle sql=\(sql, privacy: .public)")
                return false
            }
            var errorPointer: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
            if status != SQLITE_OK {
                let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
                Log.search.error("sqlite exec failed status=\(status, privacy: .public) sql=\(sql, privacy: .public) error=\(message, privacy: .public)")
            }
            if let errorPointer = errorPointer { sqlite3_free(errorPointer) }
            return status == SQLITE_OK
        }
    }

    @discardableResult
    func run(_ sql: String, _ values: [SQLiteValue] = []) -> Bool {
        sync {
            guard let statement = prepare(sql) else { return false }
            defer { sqlite3_finalize(statement) }
            guard bind(statement, values, sql: sql) else { return false }
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE || status == SQLITE_ROW else {
                logFailure("step", sql: sql, status: status)
                return false
            }
            return true
        }
    }

    @discardableResult
    func query(_ sql: String, _ values: [SQLiteValue] = [], row handler: (SQLiteRow) -> Void) -> Bool {
        sync {
            guard let statement = prepare(sql) else { return false }
            defer { sqlite3_finalize(statement) }
            guard bind(statement, values, sql: sql) else { return false }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_ROW {
                    handler(SQLiteRow(statement: statement))
                    continue
                }
                if status == SQLITE_DONE { return true }
                logFailure("step", sql: sql, status: status)
                return false
            }
        }
    }

    @discardableResult
    func transaction(_ body: () -> Bool) -> Bool {
        sync {
            guard run("BEGIN IMMEDIATE") else { return false }
            guard body() else {
                run("ROLLBACK")
                Log.search.error("sqlite transaction rolled back path=\(self.path, privacy: .public)")
                return false
            }
            guard run("COMMIT") else {
                run("ROLLBACK")
                return false
            }
            return true
        }
    }

    func changes() -> Int {
        sync {
            guard let handle = self.handle else { return 0 }
            return Int(sqlite3_changes(handle))
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let handle = self.handle else {
            Log.search.error("sqlite prepare on closed handle sql=\(sql, privacy: .public)")
            return nil
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement = statement else {
            logFailure("prepare", sql: sql, status: status)
            if let statement = statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ values: [SQLiteValue], sql: String) -> Bool {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text):
                status = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .int(let number):
                status = sqlite3_bind_int64(statement, index, number)
            case .double(let number):
                status = sqlite3_bind_double(statement, index, number)
            case .null:
                status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else {
                logFailure("bind index=\(index)", sql: sql, status: status)
                return false
            }
        }
        return true
    }

    private func logFailure(_ stage: String, sql: String, status: Int32) {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
        Log.search.error("sqlite \(stage, privacy: .public) failed status=\(status, privacy: .public) sql=\(sql, privacy: .public) error=\(message, privacy: .public)")
    }
}
