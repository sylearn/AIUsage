import Foundation
import SQLite3

// MARK: - Session Center · SQLite
// 以只读模式打开原工具的数据库：不复制、不加写锁，WAL 模式下也能与原工具并发读。
// 原工具退出后会删掉 -wal / -shm，而只读连接无权重建 -shm，WAL 库会打不开（实测 Codex 退出后即如此）；
// 此时退回 immutable=1：没有 -wal 就没有未落盘的内容，不会少读数据。
// 列名按 PRAGMA table_info 探测，表结构升级时缺列只影响对应字段。
// 可写连接（`writable(path:)`）只用于 AIUsage 自己的全文索引，从不用来打开原工具的文件。

final class SessionSQLite {
    private var db: OpaquePointer?

    private init(handle: OpaquePointer?) {
        db = handle
    }

    /// 打开（不存在则创建）AIUsage 自己的数据库，只给全文索引用。
    static func writable(path: String) -> SessionSQLite? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK,
              sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 2_000)
        return SessionSQLite(handle: handle)
    }

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        for query in ["mode=ro", "mode=ro&immutable=1"] {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2("file:\(encoded)?\(query)", &handle, flags, nil) == SQLITE_OK,
               sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK {
                db = handle
                sqlite3_busy_timeout(db, 1_000)
                return
            }
            sqlite3_close(handle)
        }
        return nil
    }

    deinit {
        sqlite3_close(db)
    }

    func tableExists(_ name: String) -> Bool {
        var found = false
        _ = query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) { _ in
            found = true
        }
        return found
    }

    func columns(of table: String) -> Set<String> {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        var names = Set<String>()
        _ = query("PRAGMA table_info(\(table))") { row in
            if let name = row.string("name") { names.insert(name) }
        }
        return names
    }

    /// 执行不返回行的语句；SQL 出错返回 false。
    @discardableResult
    func execute(_ sql: String, _ values: [BindValue] = []) -> Bool {
        if values.isEmpty {
            return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
        return query(sql, values) { _ in }
    }

    /// 最近一次插入的 rowid。
    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(db)
    }

    /// 逐行回调；SQL 出错返回 false。
    @discardableResult
    func query(_ sql: String, _ values: [BindValue] = [], row: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)

        var indexByName: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            if let name = sqlite3_column_name(statement, index) {
                indexByName[String(cString: name)] = index
            }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                row(Row(statement: statement, indexByName: indexByName))
            } else {
                return result == SQLITE_DONE
            }
        }
    }

    struct Row {
        fileprivate let statement: OpaquePointer?
        fileprivate let indexByName: [String: Int32]

        func string(_ column: String) -> String? {
            guard let index = indexByName[column],
                  sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let text = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: text)
        }

        func int64(_ column: String) -> Int64? {
            guard let index = indexByName[column], sqlite3_column_type(statement, index) != SQLITE_NULL else {
                return nil
            }
            return sqlite3_column_int64(statement, index)
        }

        func double(_ column: String) -> Double? {
            guard let index = indexByName[column], sqlite3_column_type(statement, index) != SQLITE_NULL else {
                return nil
            }
            return sqlite3_column_double(statement, index)
        }
    }
}

extension SessionSQLite {
    /// 目录下版本号最大的 `<prefix><N>.sqlite`（如 `state_5.sqlite`）。
    static func newestVersionedDatabase(in directory: String, prefix: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        let candidates = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(prefix.count).dropLast(".sqlite".count)) else { return nil }
            return (version, name)
        }
        guard let newest = candidates.max(by: { $0.0 < $1.0 }) else { return nil }
        return (directory as NSString).appendingPathComponent(newest.1)
    }

    /// 数据库与其 WAL 文件的指纹；两者都没变才复用缓存。
    static func fingerprint(_ path: String?) -> [FileFingerprint?] {
        guard let path else { return [] }
        return [FileFingerprint(path: path), FileFingerprint(path: path + "-wal")]
    }
}
