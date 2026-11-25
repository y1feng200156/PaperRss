import Foundation
import XCTest
@testable import PaperRssCore

private actor ArticleChatTestPort: AIModelPort {
    private(set) var request: URLRequest?

    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        XCTFail("Expected a streaming request")
        throw LLMServiceError.invalidResponse
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        self.request = request
        return AIModelEventResponse(statusCode: 200, lines: AsyncThrowingStream { continuation in
            continuation.yield(#"data: {"choices":[{"delta":{"content":"The article cites one study."}}]}"#)
            continuation.yield("data: [DONE]")
            continuation.finish()
        })
    }
}

final class ArticleChatTests: XCTestCase {
    func testCodexArticleChatStreamsOnlyTheCurrentReplyAndKeepsTheFinalText() async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
        try files.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        try Data("{}".utf8).write(to: codexHome.appendingPathComponent("auth.json"))
        try Data("fixture configuration".utf8).write(to: codexHome.appendingPathComponent("config.toml"))
        let executable = directory.appendingPathComponent("codex")
        try #"""
        #!/bin/sh
        [ "$1" = "app-server" ] && [ -L "$CODEX_HOME/auth.json" ] && [ ! -e "$CODEX_HOME/config.toml" ] || exit 1
        while IFS= read -r line; do
            case "$line" in
                *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
                *'"method":"initialized"'*) ;;
                *'"method":"account/read"'*) printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}' ;;
                *'"method":"thread/start"'*)
                    case "$line" in *'Synthetic evidence'*) exit 1 ;; esac
                    for value in '"ephemeral":true' '"environments":[]' '"approvalPolicy":"never"' '"model":"fixture-model"'; do
                        case "$line" in *"$value"*) ;; *) exit 1 ;; esac
                    done
                    printf '%s\n' '{"id":3,"result":{"thread":{"id":"article-thread"}}}' ;;
                *'"method":"turn/start"'*)
                    case "$line" in *'Synthetic evidence'*) ;; *) exit 1 ;; esac
                    printf '%s\n' '{"method":"item/started","params":{"threadId":"article-thread","turnId":"article-turn","item":{"id":"note","type":"agentMessage","phase":"commentary"}}}'
                    printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"article-thread","turnId":"article-turn","itemId":"note","delta":"Working..."}}'
                    printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"other","turnId":"article-turn","itemId":"reply","delta":"Unrelated"}}'
                    printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"article-thread","turnId":"article-turn","itemId":"reply","delta":"合成"}}'
                    printf '%s\n' '{"id":4,"result":{"turn":{"id":"article-turn","status":"inProgress"}}}'
                    while [ ! -f "$HOME/first-delta" ]; do /bin/sleep 0.02; done
                    printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"article-thread","turnId":"article-turn","itemId":"reply","delta":"文章"}}'
                    printf '%s\n' '{"method":"item/completed","params":{"threadId":"article-thread","turnId":"article-turn","item":{"id":"reply","type":"agentMessage","phase":"final_answer","text":"合成文章。"}}}'
                    printf '%s\n' '{"method":"turn/completed","params":{"threadId":"article-thread","turn":{"id":"article-turn","status":"completed"}}}' ;;
                *) exit 1 ;;
            esac
        done
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = LLMService(
            port: ArticleChatTestPort(), translationScheduler: TranslationRequestScheduler(),
            codexCLI: CodexCLI(environment: ["HOME": directory.path, "PATH": directory.path], timeout: .seconds(5))
        )
        let provider = try XCTUnwrap(AISettings.default.provider(id: AIProviderID.codexCLI))
        let config = provider.runtimeConfiguration(modelID: "fixture-model", features: .default)
        let answer = try await service.askArticle(
            title: "Fixture", text: "Synthetic evidence", question: "Summarize it.",
            history: [], configuration: config, apiKey: ""
        ) { delta in
            XCTAssertTrue(delta == "合成" || delta == "文章")
            if delta == "合成" { try? Data().write(to: directory.appendingPathComponent("first-delta")) }
        }
        XCTAssertEqual(answer, "合成文章。")
    }

    func testArticleChatSendsTheArticleAndRecentTurnsWithTheFollowUp() async throws {
        let port = ArticleChatTestPort()
        let service = LLMService(port: port)
        var config = LLMConfiguration.deepSeek
        config.targetLanguage = "English"
        let history = (1...10).map { ArticleChatTurn(question: "Question \($0)", answer: "Answer \($0)") }
        let text = "The author cites one study in the evidence section."
        let answer = try await service.askArticle(
            title: "Evidence", text: text, question: " What did that source measure? ",
            history: history, configuration: config, apiKey: "fixture-key", onDelta: { _ in }
        )
        XCTAssertEqual(answer, "The article cites one study.")
        let recorded = await port.request
        let request = try XCTUnwrap(recorded)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]?.contains("in English") == true)
        let payload = try XCTUnwrap(messages[1]["content"])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(context["article"] as? String, text)
        XCTAssertEqual(context["currentQuestion"] as? String, "What did that source measure?")
        let turns = try XCTUnwrap(context["recentConversation"] as? [[String: String]])
        XCTAssertEqual(turns.compactMap { $0["answer"] }, Array(history.suffix(8)).map(\.answer))
        XCTAssertFalse(payload.contains("fixture-key"))
    }

    func testExistingSettingsSeedArticleChatFromSummary() throws {
        let reference = AIModelReference(providerID: AIProviderID.gemini, modelID: "gemini-3.8-flash")
        let summary = AIFeatureConfiguration(isEnabled: false, model: reference, reasoningMode: "高")
        let old = AISettings(
            activeProviderID: AIProviderID.deepSeek,
            providers: AISettings.default.providers,
            features: .default,
            featureConfigurations: [.summary: summary]
        )
        let migrated = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(old)).migratedToCurrentSchema()

        XCTAssertEqual(migrated.configuration(for: .summary), summary)
        XCTAssertEqual(
            migrated.configuration(for: .articleChat),
            AIFeatureConfiguration(isEnabled: true, model: reference, reasoningMode: "高")
        )
    }

    func testSavedArticleChatSettingsRemainReadableByOlderVersions() throws {
        struct LegacySettings: Decodable {
            enum Feature: String, Codable { case summary }
            let featureConfigurations: [Feature: AIFeatureConfiguration]
        }
        let reference = AIModelReference(providerID: AIProviderID.gemini, modelID: "gemini-3.8-flash")
        let summary = AIFeatureConfiguration(isEnabled: true, model: reference)
        let chat = AIFeatureConfiguration(isEnabled: false, model: reference, reasoningMode: "高")
        let settings = AISettings(
            activeProviderID: reference.providerID, providers: AISettings.default.providers,
            features: .default, featureConfigurations: [.summary: summary, .articleChat: chat]
        )

        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(LegacySettings.self, from: encoded).featureConfigurations, [.summary: summary])
        XCTAssertEqual(try JSONDecoder().decode(AISettings.self, from: encoded), settings)
    }
}
