import Foundation
import GRDB

public enum KeywordMuteScope: Hashable, Sendable {
    case feed(UUID)
    case folder(accountID: String, name: String)

    var timelineScope: TimelineScope {
        switch self {
        case .feed(let id): .feed(feedID: id.uuidString)
        case .folder(let accountID, let name): .folder(accountID: accountID, folderName: name)
        }
    }

    private func target(in db: Database) throws -> (column: String, id: String)? {
        switch self {
        case .feed(let id):
            return try String.fetchOne(db, sql: """
                SELECT id FROM feeds WHERE id = ? AND is_deleted = 0
                """, arguments: [id.uuidString]).map { ("feed_id", $0) }
        case .folder(let accountID, let name):
            return try String.fetchOne(db, sql: """
                SELECT id FROM folders WHERE account_id = ? AND name = ? AND is_deleted = 0
                ORDER BY id LIMIT 1
                """, arguments: [accountID, name]).map { ("folder_id", $0) }
        }
    }

    func fetchRule(in db: Database) throws -> KeywordMuteRule {
        guard let target = try target(in: db) else { throw KeywordMuteRule.ScopeUnavailable() }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT keywords, is_enabled FROM keyword_mute_rules WHERE \(target.column) = ?
            """, arguments: [target.id]) else { return KeywordMuteRule() }
        let data: Data = row["keywords"]
        return try KeywordMuteRule(
            keywords: JSONDecoder().decode([String].self, from: data),
            isEnabled: row["is_enabled"]
        )
    }

    func save(_ rule: KeywordMuteRule, in db: Database) throws {
        guard let target = try target(in: db) else { throw KeywordMuteRule.ScopeUnavailable() }
        if rule.keywords.isEmpty {
            try db.execute(sql: "DELETE FROM keyword_mute_rules WHERE \(target.column) = ?", arguments: [target.id])
        } else {
            try db.execute(sql: """
                INSERT INTO keyword_mute_rules (\(target.column), keywords, is_enabled)
                VALUES (?, ?, ?)
                ON CONFLICT (\(target.column)) DO UPDATE
                SET keywords = excluded.keywords, is_enabled = excluded.is_enabled
                """, arguments: [target.id, try JSONEncoder().encode(rule.keywords), rule.isEnabled])
        }
    }
}

public struct KeywordMuteRule: Hashable, Sendable {
    public let keywords: [String]
    public let isEnabled: Bool

    public init(keywords: [String] = [], isEnabled: Bool = true) {
        var seen: Set<String> = []
        self.keywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        self.isEnabled = isEnabled
    }

    struct ScopeUnavailable: Error {}

    static let matches = DatabaseFunction("keyword_mute_matches", argumentCount: 3, pure: true) { values in
        guard let data = Data.fromDatabaseValue(values[2]),
              let keywords = try? JSONDecoder().decode([String].self, from: data) else { return false }
        let title = HTMLTextDecoder.decoded(String.fromDatabaseValue(values[0]) ?? "")
        let summary = HTMLTextDecoder.decoded(String.fromDatabaseValue(values[1]) ?? "")
        return keywords.contains { keyword in
            title.range(of: keyword, options: .caseInsensitive) != nil
                || summary.range(of: keyword, options: .caseInsensitive) != nil
        }
    }

    static func hasEnabledRules(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM keyword_mute_rules WHERE is_enabled = 1)") ?? false
    }

    static func mutedIDs(_ ids: [String], in db: Database) throws -> Set<String> {
        guard !ids.isEmpty, try hasEnabledRules(in: db) else { return [] }
        let idsJSON = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        return try Set(String.fetchAll(db, sql: """
            SELECT i.id
            FROM json_each(?) candidates
            JOIN items i ON i.id = candidates.value
            JOIN articles a ON a.item_id = i.id
            WHERE \(isMutedSQL())
            """, arguments: [idsJSON]))
    }

    /// Requires an item aliased as `i` and its article under the given alias.
    static func isMutedSQL(articleAlias: String = "a") -> String {
        """
        EXISTS (
            SELECT 1 FROM keyword_mute_rules r
            WHERE r.feed_id = i.feed_id AND r.is_enabled = 1
              AND keyword_mute_matches(\(articleAlias).title, \(articleAlias).summary, r.keywords)
            UNION ALL
            SELECT 1 FROM feed_folders mute_link
            JOIN folders mute_folder ON mute_folder.id = mute_link.folder_id
            JOIN keyword_mute_rules r ON r.folder_id = mute_folder.id
            WHERE mute_link.feed_id = i.feed_id AND mute_folder.account_id = i.account_id
              AND mute_folder.is_deleted = 0 AND r.is_enabled = 1
              AND keyword_mute_matches(\(articleAlias).title, \(articleAlias).summary, r.keywords)
        )
        """
    }
}
