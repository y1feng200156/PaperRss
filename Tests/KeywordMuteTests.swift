import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class KeywordMuteTests: XCTestCase {
    @MainActor
    func testRefreshOmitsMutedArticlesFromNotificationsAndKeepsThemAvailable() async throws {
        let feed = Feed(id: UUID(), title: "Fixture", feedURL: URL(string: "https://example.test/feed")!)
        let store = AppStore(
            testDatabase: AppDatabase(
                feeds: [feed], entries: [], articleCaches: [:], readingStates: [:], artifacts: [], llmConfiguration: .default
            ),
            feedFetcher: { feed in
                let items = [
                    ParsedFeedEntry(id: "sponsored", title: "Sponsored", author: nil, url: nil,
                        publishedAt: Date(), summary: "", contentHTML: nil),
                    ParsedFeedEntry(id: "news", title: "News", author: nil, url: nil,
                        publishedAt: Date(), summary: "", contentHTML: nil),
                ]
                return .updated(ParsedFeed(title: feed.title, siteURL: nil, iconURL: nil, entries: items),
                    etag: nil, lastModified: nil)
            }
        )
        let scope = KeywordMuteScope.feed(feed.id)
        try await store.saveKeywordMuteRule(KeywordMuteRule(keywords: ["sponsored"]), for: scope)
        let outcome = await store.refresh()
        XCTAssertEqual(outcome?.newUnreadEntries.map(\.title), ["News"])
        XCTAssertEqual(store.sidebarCounts.allUnread, 1)
        let hidden = try await store.keywordMuteArticles(in: scope, limit: 10)
        XCTAssertEqual(hidden.map(\.title), ["Sponsored"])
        XCTAssertEqual(hidden.first?.isRead, false)
    }

    func testRulesFilterBeforePagingAndKeepHiddenArticlesUnread() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let local = LocalAccountProvider(accountID: "local-default", database: database)
        let other = LocalAccountProvider(accountID: "other", database: database)
        for provider in [local, other] {
            try provider.ensureAccountExists()
            try provider.addFolder(name: "Tech")
        }

        let target = try local.addFeed(title: "Target", feedURL: URL(string: "https://example.test/target")!, folder: "Tech")
        let outside = try local.addFeed(title: "Outside", feedURL: URL(string: "https://example.test/outside")!)
        let foreign = try other.addFeed(title: "Foreign", feedURL: URL(string: "https://example.test/foreign")!, folder: "Tech")
        try insert(
            [("Newest", "ordinary"), ("SPONSORED post", ""), ("Review", "含广告"), ("Offers", "50% off"),
             ("Another review", "plain"), ("Oldest", "ordinary")], in: target, provider: local
        )
        try insert([("Sponsored outside", ""), ("Another review", "plain")], in: outside, provider: local)
        try insert([("Sponsored abroad", "")], in: foreign, provider: other)

        let query = local.timelineQueryService
        let folder = KeywordMuteScope.folder(accountID: "local-default", name: "Tech")
        let feed = KeywordMuteScope.feed(target.id)
        let folderRule = KeywordMuteRule(keywords: [" sponsored ", "广告", "%", "SPONSORED", ""])
        let feedRule = KeywordMuteRule(keywords: ["Another review"])
        let preview = try database.read {
            try query.fetchListItems(scope: folder.timelineScope, keywordFilter: .matching(folderRule), in: $0)
        }
        XCTAssertEqual(preview.map(\.title), ["SPONSORED post", "Review", "Offers"])
        XCTAssertEqual(try query.fetchListItems(scope: feed.timelineScope).count, 6)

        try database.write {
            try folder.save(folderRule, in: $0)
            try feed.save(feedRule, in: $0)
        }
        let first = try query.fetchListItems(scope: feed.timelineScope, limit: 1)
        let second = try query.fetchListItems(scope: feed.timelineScope, limit: 1, offset: 1)
        XCTAssertEqual((first + second).map(\.title), ["Newest", "Oldest"])
        let current = try XCTUnwrap(first.first)
        let next = try query.fetchAdjacentItem(scope: feed.timelineScope, currentItemID: current.id, direction: .next)
        XCTAssertEqual(next?.title, "Oldest")
        XCTAssertEqual(try query.fetchListItems(scope: .all).count, 5)
        XCTAssertEqual(try query.fetchSidebarCounts(startOfDayTimestamp: 0).allUnread, 5)
        XCTAssertEqual(try query.fetchSidebarCounts(startOfDayTimestamp: 0).unreadCount(folder: "Tech"), 2)
        XCTAssertEqual(try query.fetchSidebarCounts(startOfDayTimestamp: 0).unreadCount(folder: "Tech", accountID: "other"), 1)

        let hidden = try database.read {
            try query.fetchListItems(scope: feed.timelineScope, keywordFilter: .hidden, in: $0)
        }
        XCTAssertEqual(hidden.map(\.title), preview.map(\.title) + ["Another review"])
        let mutedIDs = try database.read {
            try KeywordMuteRule.mutedIDs([current.id] + hidden.map(\.id), in: $0)
        }
        XCTAssertEqual(mutedIDs, Set(hidden.map(\.id)))
        try database.write {
            try local.stateRepository.markAllRead(feedID: target.id.uuidString, excludingMuted: true, in: $0)
        }
        let all = try query.fetchListItems(scope: feed.timelineScope, includeMuted: true)
        XCTAssertEqual(all.filter { !$0.isRead }.map(\.id), hidden.map(\.id))
        XCTAssertEqual(try query.fetchSidebarCounts(startOfDayTimestamp: 0).unreadCount(folder: "Tech"), 0)

        try insert([("New sponsored article", "")], in: target, provider: local, time: 2_000)
        XCTAssertEqual(try query.fetchListItems(scope: feed.timelineScope, limit: 1).first?.title, "Newest")
        try local.renameFolder(oldName: "Tech", newName: "Technology")
        let renamedFolder = KeywordMuteScope.folder(accountID: "local-default", name: "Technology")
        XCTAssertEqual(try database.read { try renamedFolder.fetchRule(in: $0) }, folderRule)
        try database.write {
            try renamedFolder.save(KeywordMuteRule(keywords: folderRule.keywords, isEnabled: false), in: $0)
        }
        XCTAssertEqual(try query.fetchListItems(scope: feed.timelineScope, limit: 1).first?.title, "New sponsored article")
        XCTAssertEqual(try query.fetchListItems(scope: feed.timelineScope, unreadOnly: true).count, 4)
        let reopened = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        XCTAssertFalse(try reopened.read { try renamedFolder.fetchRule(in: $0).isEnabled })
        XCTAssertEqual(try reopened.read { try feed.fetchRule(in: $0) }, feedRule)
    }

    private func insert(
        _ entries: [(title: String, summary: String)], in feed: Feed, provider: LocalAccountProvider, time: Double = 1_000
    ) throws {
        let items = entries.enumerated().map { index, entry in
            ParsedFeedEntry(
                id: "\(time)-\(index)", title: entry.title, author: nil, url: nil,
                publishedAt: Date(timeIntervalSince1970: time - Double(index)),
                summary: entry.summary, contentHTML: nil
            )
        }
        _ = try provider.applyRefreshResult(.init(feedID: feed.id, oldTitle: feed.title,
            result: .success(.updated(
                ParsedFeed(title: feed.title, siteURL: nil, iconURL: nil, entries: items), etag: nil, lastModified: nil
            ))))
    }
}
