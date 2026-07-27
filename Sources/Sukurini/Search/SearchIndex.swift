import Foundation
import os

final class SearchIndex: SearchProviding {
    private static let maximumStoredCharacters = 60_000
    private static let maximumQueryTokens = 6
    private static let deleteChunkSize = 200
    private static let moveChunkSize = 200
    private static let mtimeTolerance = 0.001

    private let db: SQLiteDB
    private let ready: Bool

    var semanticSlotsReleased: (([Int]) -> Void)?

    convenience init?() {
        self.init(databaseURL: SearchIndex.defaultDatabaseURL())
    }

    init?(databaseURL: URL) {
        guard let db = SQLiteDB(url: databaseURL, label: "sukurini.search.sqlite") else {
            Log.search.error("index unavailable path=\(databaseURL.path, privacy: .public)")
            return nil
        }
        self.db = db
        self.ready = SearchIndex.createSchema(db)
        guard ready else {
            Log.search.error("index schema failed path=\(databaseURL.path, privacy: .public)")
            return nil
        }
        Log.search.info("index ready path=\(databaseURL.path, privacy: .public) indexed=\(self.indexedCount(), privacy: .public)")
    }

    var isReady: Bool { ready }

    var usesSemanticSearch: Bool { false }

    func search(query: String, completion: @escaping (SearchOutcome) -> Void) {
        search(query: query) { requested, paths in
            completion(SearchOutcome(query: requested, isRanked: false, paths: Array(paths)))
        }
    }

    func search(query: String, completion: @escaping (String, Set<String>) -> Void) {
        let requested = query
        let tokens = SearchIndex.queryTokens(from: query)
        guard ready, !tokens.isEmpty else {
            Log.search.debug("search skipped tokens=\(tokens.count, privacy: .public) ready=\(self.ready, privacy: .public)")
            DispatchQueue.main.async { completion(requested, []) }
            return
        }

        db.perform { [weak self] in
            guard let self = self else { return }
            let started = Date()
            let conditions = Array(repeating: "text LIKE ? ESCAPE '\\'", count: tokens.count).joined(separator: " AND ")
            let values = tokens.map { SQLiteValue.text("%" + SearchIndex.escapeLikePattern($0) + "%") }
            var paths = Set<String>()
            let ok = self.db.query("SELECT path FROM ocr WHERE " + conditions, values) { row in
                let path = row.text(0)
                guard !path.isEmpty else { return }
                paths.insert(path)
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.search.info("search done tokens=\(tokens.count, privacy: .public) hits=\(paths.count, privacy: .public) ms=\(elapsed, privacy: .public) ok=\(ok, privacy: .public)")
            DispatchQueue.main.async { completion(requested, paths) }
        }
    }

    func reconcile(with items: [Screenshot], folder: URL?, completion: @escaping ([Screenshot]) -> Void) {
        guard ready else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let scopes = SearchIndex.scopeDirectories(for: folder, items: items)

        db.perform { [weak self] in
            guard let self = self else { return }
            let started = Date()
            var existing: [String: (mtime: Double, size: Int64, done: Bool)] = [:]
            existing.reserveCapacity(items.count)
            self.db.query("SELECT path, mtime, size, ocr_done FROM files") { row in
                existing[row.text(0)] = (row.double(1), row.int(2), row.int(3) != 0)
            }

            var pending: [Screenshot] = []
            var live = Set<String>()
            live.reserveCapacity(items.count)
            for item in items {
                let path = item.path
                live.insert(path)
                guard let record = existing[path] else {
                    pending.append(item)
                    continue
                }
                let mtime = item.created.timeIntervalSince1970
                let changed = record.size != item.size || abs(record.mtime - mtime) > SearchIndex.mtimeTolerance
                if !record.done || changed { pending.append(item) }
            }

            var stale: [String] = []
            var skipped = "none"
            if items.isEmpty {
                skipped = "empty-item-list"
            } else if scopes.isEmpty {
                skipped = "no-folder-scope"
            } else {
                stale = existing.keys.filter { !live.contains($0) && SearchIndex.isInScope($0, scopes) }
                if !stale.isEmpty { self.deletePathsOnQueue(stale) }
            }
            if skipped != "none" {
                Log.search.error("reconcile deletion skipped reason=\(skipped, privacy: .public) known=\(existing.count, privacy: .public)")
            }

            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.search.info("reconcile done items=\(items.count, privacy: .public) known=\(existing.count, privacy: .public) pending=\(pending.count, privacy: .public) stale=\(stale.count, privacy: .public) scopes=\(scopes.count, privacy: .public) ms=\(elapsed, privacy: .public)")
            DispatchQueue.main.async { completion(pending) }
        }
    }

    func storeText(_ text: String, for screenshot: Screenshot) {
        guard ready else { return }
        let path = screenshot.path
        let mtime = screenshot.created.timeIntervalSince1970
        let size = screenshot.size
        let normalized = SearchIndex.normalizeStoredText(text)

        db.perform { [weak self] in
            guard let self = self else { return }
            var replaced = false
            let ok = self.db.transaction {
                if self.hasIndexedRowOnQueue(path) {
                    replaced = true
                    guard self.db.run("DELETE FROM ocr WHERE path = ?", [.text(path)]) else { return false }
                }
                guard self.db.run("INSERT INTO ocr(path, text) VALUES(?, ?)", [.text(path), .text(normalized)]) else { return false }
                return self.db.run(
                    "INSERT INTO files(path, mtime, size, ocr_done) VALUES(?, ?, ?, 1) ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, size=excluded.size, ocr_done=1",
                    [.text(path), .double(mtime), .int(size)]
                )
            }
            Log.search.info("store text path=\(path, privacy: .public) chars=\(normalized.count, privacy: .public) replaced=\(replaced, privacy: .public) ok=\(ok, privacy: .public)")
        }
    }

    func removePaths(_ paths: [String]) {
        guard ready, !paths.isEmpty else { return }
        db.perform { [weak self] in
            guard let self = self else { return }
            self.deletePathsOnQueue(paths)
        }
    }

    func movePaths(_ moves: [String: String]) {
        guard ready, !moves.isEmpty else { return }
        db.perform { [weak self] in
            guard let self = self else { return }
            let started = Date()
            var moved = 0
            let pairs = Array(moves)
            var index = 0

            while index < pairs.count {
                let upper = min(index + SearchIndex.moveChunkSize, pairs.count)
                let chunk = Array(pairs[index..<upper])
                index = upper

                let probed = chunk.flatMap { [$0.key, $0.value] }
                let placeholders = Array(repeating: "?", count: probed.count).joined(separator: ", ")
                var rowids: [String: Int64] = [:]
                self.db.query(
                    "SELECT rowid, path FROM ocr WHERE path IN (" + placeholders + ")",
                    probed.map { SQLiteValue.text($0) }
                ) { row in
                    rowids[row.text(1)] = row.int(0)
                }

                let ok = self.db.transaction {
                    for (old, new) in chunk {
                        if let stale = rowids[new], rowids[old] != stale {
                            guard self.db.run("DELETE FROM ocr WHERE rowid = ?", [.int(stale)]) else { return false }
                        }
                        guard self.db.run("UPDATE OR REPLACE files SET path = ? WHERE path = ?", [.text(new), .text(old)]) else { return false }
                        guard self.db.run("UPDATE OR REPLACE semantic SET path = ? WHERE path = ?", [.text(new), .text(old)]) else { return false }
                        guard let rowid = rowids[old] else { continue }
                        guard self.db.run("UPDATE ocr SET path = ? WHERE rowid = ?", [.text(new), .int(rowid)]) else { return false }
                    }
                    return true
                }
                if ok { moved += chunk.count }
            }

            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.search.info("move paths requested=\(moves.count, privacy: .public) moved=\(moved, privacy: .public) ms=\(elapsed, privacy: .public)")
        }
    }

    func indexedCount() -> Int {
        guard ready else { return 0 }
        var count = 0
        db.query("SELECT count(*) FROM files WHERE ocr_done = 1") { row in
            count = Int(row.int(0))
        }
        return count
    }

    func semanticIndexedCount(model: String) -> Int {
        guard ready else { return 0 }
        var count = 0
        db.query("SELECT count(*) FROM semantic WHERE model = ?", [.text(model)]) { row in
            count = Int(row.int(0))
        }
        return count
    }

    func semanticPending(model: String, from items: [Screenshot], completion: @escaping ([Screenshot]) -> Void) {
        guard ready else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        db.perform { [weak self] in
            guard let self = self else { return }
            var known = Set<String>()
            self.db.query("SELECT path FROM semantic WHERE model = ?", [.text(model)]) { row in
                known.insert(row.text(0))
            }
            let pending = items.filter { !known.contains($0.path) }
            Log.search.info("semantic pending model=\(model, privacy: .public) items=\(items.count, privacy: .public) known=\(known.count, privacy: .public) pending=\(pending.count, privacy: .public)")
            DispatchQueue.main.async { completion(pending) }
        }
    }

    func claimSemanticSlot(path: String, model: String) -> Int? {
        guard ready else { return nil }
        return db.sync {
            var existing: Int64?
            db.query("SELECT slot FROM semantic WHERE path = ? AND model = ?", [.text(path), .text(model)]) { row in
                existing = row.int(0)
            }
            if let existing { return Int(existing) }

            var reused: Int64?
            db.query("SELECT slot FROM semantic_free WHERE model = ? ORDER BY slot LIMIT 1", [.text(model)]) { row in
                reused = row.int(0)
            }
            var target = reused
            if target == nil {
                var maximum: Int64 = -1
                db.query("SELECT COALESCE(MAX(slot), -1) FROM semantic WHERE model = ?", [.text(model)]) { row in
                    maximum = row.int(0)
                }
                target = maximum + 1
            }
            guard let slot = target else { return nil }
            let ok = db.transaction {
                if reused != nil {
                    guard db.run("DELETE FROM semantic_free WHERE model = ? AND slot = ?", [.text(model), .int(slot)]) else { return false }
                }
                return db.run(
                    "INSERT INTO semantic(path, model, slot) VALUES(?, ?, ?) ON CONFLICT(path, model) DO UPDATE SET slot=excluded.slot",
                    [.text(path), .text(model), .int(slot)]
                )
            }
            guard ok else {
                Log.search.error("semantic slot claim failed path=\(path, privacy: .public) model=\(model, privacy: .public)")
                return nil
            }
            return Int(slot)
        }
    }

    func releaseSemanticSlot(path: String, model: String) {
        guard ready else { return }
        db.perform { [weak self] in
            guard let self = self else { return }
            var slot: Int64?
            self.db.query("SELECT slot FROM semantic WHERE path = ? AND model = ?", [.text(path), .text(model)]) { row in
                slot = row.int(0)
            }
            guard let slot else { return }
            _ = self.db.transaction {
                guard self.db.run("DELETE FROM semantic WHERE path = ? AND model = ?", [.text(path), .text(model)]) else { return false }
                return self.db.run("INSERT OR IGNORE INTO semantic_free(model, slot) VALUES(?, ?)", [.text(model), .int(slot)])
            }
            guard let handler = self.semanticSlotsReleased else { return }
            DispatchQueue.main.async { handler([Int(slot)]) }
        }
    }

    func semanticPaths(slots: [Int], model: String) -> [Int: String] {
        guard ready, !slots.isEmpty else { return [:] }
        return db.sync {
            var mapping: [Int: String] = [:]
            var index = 0
            while index < slots.count {
                let upper = min(index + SearchIndex.deleteChunkSize, slots.count)
                let chunk = Array(slots[index..<upper])
                index = upper
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                var values: [SQLiteValue] = [.text(model)]
                values.append(contentsOf: chunk.map { SQLiteValue.int(Int64($0)) })
                db.query("SELECT slot, path FROM semantic WHERE model = ? AND slot IN (" + placeholders + ")", values) { row in
                    mapping[Int(row.int(0))] = row.text(1)
                }
            }
            return mapping
        }
    }

    func forgetSemanticModel(_ model: String) {
        guard ready else { return }
        db.perform { [weak self] in
            guard let self = self else { return }
            let ok = self.db.transaction {
                guard self.db.run("DELETE FROM semantic WHERE model = ?", [.text(model)]) else { return false }
                return self.db.run("DELETE FROM semantic_free WHERE model = ?", [.text(model)])
            }
            Log.search.info("semantic model forgotten model=\(model, privacy: .public) ok=\(ok, privacy: .public)")
        }
    }

    static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Sukurini", isDirectory: true)
            .appendingPathComponent("index.sqlite", isDirectory: false)
    }

    private static func createSchema(_ db: SQLiteDB) -> Bool {
        let files = "CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER NOT NULL, ocr_done INTEGER NOT NULL DEFAULT 0);"
        let ocr = "CREATE VIRTUAL TABLE IF NOT EXISTS ocr USING fts5(path UNINDEXED, text, tokenize='trigram');"
        let semantic = "CREATE TABLE IF NOT EXISTS semantic(path TEXT NOT NULL, model TEXT NOT NULL, slot INTEGER NOT NULL, PRIMARY KEY(path, model));"
        let semanticSlot = "CREATE INDEX IF NOT EXISTS semantic_model_slot ON semantic(model, slot);"
        let semanticFree = "CREATE TABLE IF NOT EXISTS semantic_free(model TEXT NOT NULL, slot INTEGER NOT NULL, PRIMARY KEY(model, slot));"
        guard db.execute(files) else { return false }
        guard db.execute(ocr) else { return false }
        guard db.execute(semantic) else { return false }
        guard db.execute(semanticSlot) else { return false }
        guard db.execute(semanticFree) else { return false }
        return true
    }

    private func hasIndexedRowOnQueue(_ path: String) -> Bool {
        var found = false
        db.query("SELECT 1 FROM files WHERE path = ? AND ocr_done = 1 LIMIT 1", [.text(path)]) { _ in
            found = true
        }
        return found
    }

    private func deletePathsOnQueue(_ paths: [String]) {
        let started = Date()
        var removed = 0
        var index = 0
        var released: [Int] = []
        while index < paths.count {
            let upper = min(index + SearchIndex.deleteChunkSize, paths.count)
            let chunk = Array(paths[index..<upper])
            index = upper
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let values = chunk.map { SQLiteValue.text($0) }
            var freed: [(Int64, String)] = []
            db.query("SELECT slot, model FROM semantic WHERE path IN (" + placeholders + ")", values) { row in
                freed.append((row.int(0), row.text(1)))
            }
            let ok = db.transaction {
                guard db.run("DELETE FROM ocr WHERE path IN (" + placeholders + ")", values) else { return false }
                guard db.run("DELETE FROM semantic WHERE path IN (" + placeholders + ")", values) else { return false }
                for (slot, model) in freed {
                    guard db.run("INSERT OR IGNORE INTO semantic_free(model, slot) VALUES(?, ?)", [.text(model), .int(slot)]) else { return false }
                }
                return db.run("DELETE FROM files WHERE path IN (" + placeholders + ")", values)
            }
            if ok {
                removed += chunk.count
                released.append(contentsOf: freed.map { Int($0.0) })
            }
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.search.info("remove paths requested=\(paths.count, privacy: .public) removed=\(removed, privacy: .public) semanticFreed=\(released.count, privacy: .public) ms=\(elapsed, privacy: .public)")
        guard !released.isEmpty, let handler = semanticSlotsReleased else { return }
        DispatchQueue.main.async { handler(released) }
    }

    private static func scopeDirectories(for folder: URL?, items: [Screenshot]) -> Set<String> {
        var directories = Set<String>()
        if let folder = folder {
            for path in [folder.path, folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path] {
                let trimmed = trimTrailingSlash(path)
                guard !trimmed.isEmpty else { continue }
                directories.insert(trimmed)
            }
        }
        for item in items {
            let parent = trimTrailingSlash(item.url.deletingLastPathComponent().path)
            guard !parent.isEmpty else { continue }
            directories.insert(parent)
        }
        return directories
    }

    private static func isInScope(_ path: String, _ directories: Set<String>) -> Bool {
        guard let separator = path.lastIndex(of: "/") else { return false }
        let parent = trimTrailingSlash(String(path[path.startIndex..<separator]))
        guard !parent.isEmpty else { return false }
        if directories.contains(parent) { return true }
        for directory in directories where parent.hasPrefix(directory + "/") {
            return true
        }
        return false
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        var value = path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func queryTokens(from query: String) -> [String] {
        let normalized = query.precomposedStringWithCanonicalMapping
        let pieces = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !pieces.isEmpty else { return [] }
        return Array(pieces.prefix(maximumQueryTokens))
    }

    private static func escapeLikePattern(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 4)
        for character in value {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func normalizeStoredText(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        var lines: [String] = []
        for raw in composed.components(separatedBy: .newlines) {
            let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !collapsed.isEmpty else { continue }
            lines.append(collapsed)
        }
        let joined = lines.joined(separator: "\n")
        guard joined.count > maximumStoredCharacters else { return joined }
        Log.search.info("store text truncated chars=\(joined.count, privacy: .public) limit=\(maximumStoredCharacters, privacy: .public)")
        return String(joined.prefix(maximumStoredCharacters))
    }
}
