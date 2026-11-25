import AppKit
import PaperRssCore
import SwiftUI
import XCTest
@testable import PaperRssDesktop

final class ArticleChatSessionTests: XCTestCase {
    @MainActor
    func testReplyPublishesPartialTextBeforeCompletion() async throws {
        let session = ArticleChatSession()
        var finishReply: CheckedContinuation<Void, Never>?
        session.drafts["article"] = "What is the main claim?"
        session.send(entryID: "article") { _, _, onDelta in
            await onDelta("作者👩🏽‍🔬引用")
            await withCheckedContinuation { finishReply = $0 }
            await onDelta("了一项研究。")
            return "作者👩🏽‍🔬引用了一项研究。"
        }

        let first = try await waitForPartialText(in: session) { finishReply != nil }
        let continuation = try XCTUnwrap(finishReply)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue("作者👩🏽‍🔬引用".hasPrefix(first))
        XCTAssertLessThan(first.count, "作者👩🏽‍🔬引用".count)
        XCTAssertNil(session.turns["article"])
        continuation.resume()

        try await waitForReply(in: session)
        XCTAssertEqual(session.turns["article"]?.map(\.answer), ["作者👩🏽‍🔬引用了一项研究。"])
    }

    @MainActor
    func testFollowUpsUseOnlyTheCurrentArticlesCompletedTurns() async throws {
        let session = ArticleChatSession()
        session.drafts["first"] = "What is the main claim?"
        session.send(entryID: "first") { _, history, _ in
            XCTAssertTrue(history.isEmpty)
            return "The main claim."
        }
        try await waitForReply(in: session)

        session.drafts["second"] = "What evidence does the writer cite?"
        session.send(entryID: "second") { _, history, _ in
            XCTAssertTrue(history.isEmpty)
            return "Unrelated evidence."
        }
        try await waitForReply(in: session)

        session.drafts["first"] = "What supports that claim?"
        session.send(entryID: "first") { question, history, _ in
            XCTAssertEqual(question, "What supports that claim?")
            XCTAssertEqual(history, [ArticleChatTurn(question: "What is the main claim?", answer: "The main claim.")])
            return "A single study."
        }
        try await waitForReply(in: session)
        XCTAssertEqual(session.turns["first"]?.last?.answer, "A single study.")
        XCTAssertEqual(session.turns["second"]?.count, 1)
    }

    @MainActor
    func testStoppingRestoresTheDraftAndDiscardsLateDeltas() async throws {
        let session = ArticleChatSession()
        var releaseReply: CheckedContinuation<Void, Never>?
        var didDeliverLateDelta = false
        session.drafts["first"] = "Read the conclusion."
        session.send(entryID: "first") { _, _, onDelta in
            await onDelta("A first paragraph already queued for display.")
            await withCheckedContinuation { releaseReply = $0 }
            await onDelta("Late response.")
            didDeliverLateDelta = true
            return "Late response."
        }
        _ = try await waitForPartialText(in: session) { releaseReply != nil }
        let continuation = try XCTUnwrap(releaseReply)
        session.stop(entryID: "first")
        continuation.resume()
        for _ in 0..<500 {
            if didDeliverLateDelta { break }
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertTrue(didDeliverLateDelta)
        XCTAssertEqual(session.drafts["first"], "Read the conclusion.")
        XCTAssertNil(session.submission)
        XCTAssertNil(session.turns["first"])
        XCTAssertNil(session.errors["first"])
    }

    @MainActor
    private func waitForPartialText(in session: ArticleChatSession, ready: () -> Bool) async throws -> String {
        for _ in 0..<500 {
            if ready(), let answer = session.submission?.answer, !answer.isEmpty { return answer }
            try await Task.sleep(for: .milliseconds(2))
        }
        return ""
    }

    @MainActor
    private func waitForReply(in session: ArticleChatSession) async throws {
        for _ in 0..<500 {
            if session.submission == nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(session.submission)
    }
}

@MainActor
final class ArticleChatPresentationTests: XCTestCase {
    func testReducedMotionShowsAndRemovesThePanelImmediately() throws {
        let view = ArticleChatPresentationView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        view.updatePanel(AnyView(Text("Article Chat")), animated: false)

        let layer = try XCTUnwrap(view.subviews.first?.layer)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(layer.transform.m41, 0)
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)

        view.updatePanel(nil, animated: false)
        XCTAssertTrue(view.subviews.isEmpty)
    }

    func testOpeningAndClosingRenderIntermediatePanelFrames() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPERRSS_RUN_GUI_TESTS"] == "1")
        _ = NSApplication.shared
        let frame = NSRect(x: -2000, y: -2000, width: 320, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let view = ArticleChatPresentationView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }

        view.updatePanel(AnyView(Text("Article Chat").frame(maxWidth: .infinity, maxHeight: .infinity)), animated: true)
        let layer = try XCTUnwrap(view.subviews.first?.layer)
        try await assertIntermediateFrame(on: layer)
        for _ in 0..<50 {
            if layer.animationKeys()?.isEmpty != false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(layer.transform.m41, 0)

        view.updatePanel(nil, animated: true)
        XCTAssertFalse(view.subviews.isEmpty)
        try await assertIntermediateFrame(on: layer)
        for _ in 0..<50 {
            if view.subviews.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(view.subviews.isEmpty)
    }

    private func assertIntermediateFrame(on layer: CALayer) async throws {
        for _ in 0..<40 {
            if let frame = layer.presentation(), frame.opacity > 0.05, frame.opacity < 0.95,
               frame.transform.m41 > 1, frame.transform.m41 < 31 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected the visible panel to fade and move before the transition ends")
    }
}
