import SwiftUI
#if os(macOS)
import AppKit
#endif
#if SWIFT_PACKAGE
import PaperRssCore
#endif

@MainActor
final class ArticleChatSession: ObservableObject {
    typealias Reply = @MainActor (
        String, [ArticleChatTurn], @escaping @Sendable (String) async -> Void
    ) async throws -> String

    struct Submission {
        let id = UUID()
        let entryID: String
        let question: String
        var answer = ""
    }

    @Published private(set) var submission: Submission?
    @Published private(set) var turns: [String: [ArticleChatTurn]] = [:]
    @Published var drafts: [String: String] = [:]
    @Published private(set) var errors: [String: any Error] = [:]
    private var task: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var pendingReply = ""

    func send(entryID: String, animateReply: Bool = true, reply: @escaping Reply) {
        let question = drafts[entryID, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, submission == nil else { return }
        let current = Submission(entryID: entryID, question: question)
        let history = turns[entryID, default: []]
        errors[entryID] = nil
        drafts[entryID] = nil
        submission = current
        task = Task { [weak self] in
            do {
                let answer = try await reply(question, history) { [weak self] delta in
                    await self?.receive(delta, for: current.id, animated: animateReply)
                }
                guard let self, submission?.id == current.id else { return }
                await revealTask?.value
                try Task.checkCancellation()
                guard submission?.id == current.id else { return }
                turns[entryID, default: []].append(ArticleChatTurn(question: question, answer: answer))
                submission = nil
                task = nil
            } catch {
                guard let self, submission?.id == current.id else { return }
                errors[entryID] = error
                stop(entryID: entryID)
            }
        }
    }

    @discardableResult
    func stop(entryID: String) -> Bool {
        guard let submission, submission.entryID == entryID else { return false }
        task?.cancel()
        task = nil
        revealTask?.cancel()
        revealTask = nil
        pendingReply = ""
        drafts[entryID] = submission.question
        self.submission = nil
        return true
    }

    private func receive(_ delta: String, for requestID: UUID, animated: Bool) {
        guard submission?.id == requestID, !delta.isEmpty else { return }
        guard animated else {
            submission?.answer.append(delta)
            return
        }
        pendingReply.append(delta)
        guard revealTask == nil else { return }
        revealTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.revealNextText(for: requestID) == true else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func revealNextText(for requestID: UUID) -> Bool {
        guard submission?.id == requestID else { return false }
        guard !pendingReply.isEmpty else {
            revealTask = nil
            return false
        }
        // Show individual characters for small deltas and catch up after a large burst.
        let count = min(8, max(1, pendingReply.count / 16))
        let end = pendingReply.index(pendingReply.startIndex, offsetBy: count)
        submission?.answer.append(contentsOf: pendingReply[..<end])
        pendingReply.removeSubrange(..<end)
        return true
    }
}

#if os(macOS)
struct ArticleChatPresentation: NSViewRepresentable {
    let panel: AnyView?
    let reduceMotion: Bool

    func makeNSView(context: Context) -> ArticleChatPresentationView {
        ArticleChatPresentationView()
    }

    func updateNSView(_ view: ArticleChatPresentationView, context: Context) {
        view.updatePanel(panel, animated: !reduceMotion)
    }
}

final class ArticleChatPresentationView: NSView {
    private static let slideDistance: CGFloat = 32
    private static let animationKey = "articleChatPresentation"
    private var host: NSHostingView<AnyView>?
    private var isOpen = false
    private var animationID = 0

    func updatePanel(_ panel: AnyView?, animated: Bool) {
        if let panel {
            if let host {
                host.rootView = panel
            } else {
                let host = NSHostingView(rootView: panel)
                host.frame = bounds
                host.autoresizingMask = [.width, .height]
                host.wantsLayer = true
                host.layer?.opacity = 0
                host.layer?.transform = CATransform3DMakeTranslation(Self.slideDistance, 0, 0)
                self.host = host
                addSubview(host)
            }
        }

        let shouldOpen = panel != nil
        guard shouldOpen != isOpen, let host, let layer = host.layer else { return }
        isOpen = shouldOpen
        animationID += 1
        let currentAnimationID = animationID
        let presentedLayer = layer.presentation() ?? layer
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presentedLayer.opacity
        fade.toValue = shouldOpen ? 1 : 0
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = presentedLayer.transform.m41
        slide.toValue = shouldOpen ? 0 : Self.slideDistance
        let duration: TimeInterval = 0.28
        fade.duration = duration
        slide.duration = duration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.opacity = shouldOpen ? 1 : 0
        layer.transform = CATransform3DMakeTranslation(shouldOpen ? 0 : Self.slideDistance, 0, 0)
        if animated {
            let motion = CAAnimationGroup()
            motion.animations = [fade, slide]
            motion.duration = duration
            motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if !shouldOpen {
                CATransaction.setCompletionBlock { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, animationID == currentAnimationID else { return }
                        removePanel()
                    }
                }
            }
            layer.add(motion, forKey: Self.animationKey)
        } else if !shouldOpen {
            removePanel()
        }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen, let hit = super.hitTest(point), hit !== self else { return nil }
        return hit
    }

    private func removePanel() {
        host?.removeFromSuperview()
        host = nil
    }
}

struct ArticleChatPanel: View {
    @ObservedObject var session: ArticleChatSession
    let entryID: String
    let palette: ReaderAppearancePalette
    let unavailableMessage: String?
    let reply: ArticleChatSession.Reply
    let onClose: () -> Void
    @FocusState private var composerFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ink: Color { Color(paperHex: palette.inkHex) }
    private var muted: Color { Color(paperHex: palette.mutedHex) }
    private var accent: Color { Color(paperHex: palette.accentHex) }
    private var wash: Color { Color(paperRGBA: palette.washCSS) ?? accent.opacity(0.09) }
    private var rule: Color {
        if contrast == .increased { return ink.opacity(0.5) }
        return Color(paperRGBA: palette.ruleCSS) ?? ink.opacity(0.16)
    }

    private var history: [ArticleChatTurn] { session.turns[entryID, default: []] }
    private var submission: ArticleChatSession.Submission? {
        session.submission?.entryID == entryID ? session.submission : nil
    }
    private var draft: Binding<String> {
        Binding(get: { session.drafts[entryID, default: ""] },
                set: { session.drafts[entryID] = $0.isEmpty ? nil : $0 })
    }
    private var canSend: Bool {
        unavailableMessage == nil && session.submission == nil
            && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let isDark = palette.colorScheme == .dark

        let panel = VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 8) {
                Text(I18N.localized("文章对话", englishFallback: "Article Chat"))
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                closeButton
            }
            .padding(.top, 10)
            .padding(.leading, 16)
            .padding(.trailing, 10)
            conversation
            composer
                .padding(12)
        }
        .font(.callout)
        .foregroundStyle(ink)
        .tint(accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(outline)

        return Group {
            if #available(macOS 26.0, *) {
                panel.glassEffect(.regular, in: outline)
            } else {
                panel.background(Color(paperHex: palette.backgroundHex), in: outline)
                    .shadow(color: .black.opacity(isDark ? 0.44 : 0.2), radius: 14, y: 6)
            }
        }
        .contentShape(outline)
        .environment(\.colorScheme, isDark ? .dark : .light)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            composerFocused = unavailableMessage == nil
        }
        .onDisappear { session.stop(entryID: entryID) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.articleChat.panel")
    }

    private var closeButton: some View {
        ReaderGlassButton(
            systemImage: "xmark",
            label: I18N.localized("关闭文章对话", englishFallback: "Close Article Chat"),
            color: ink,
            action: onClose
        )
        .accessibilityIdentifier("reader.articleChat.close")
    }

    private var conversation: some View {
        ScrollViewReader { scroll in
            let scrollView = ScrollView {
                transcript
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .frame(maxHeight: .infinity)
            .onAppear { if !history.isEmpty { scroll.scrollTo("articleChatEnd", anchor: .bottom) } }
            .onChange(of: submission?.id) { _, request in
                if request != nil { scroll.scrollTo("articleChatEnd", anchor: .bottom) }
            }

            if #available(macOS 15.0, *) {
                scrollView.defaultScrollAnchor(submission == nil ? nil : .bottom, for: .sizeChanges)
            } else {
                scrollView.onChange(of: submission?.answer) { _, answer in
                    if answer != nil { scroll.scrollTo("articleChatEnd", anchor: .bottom) }
                }
            }
        }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if history.isEmpty && submission == nil {
                Text(I18N.localized(
                    "发送提问时，正文和近期对话会提供给所选模型。",
                    englishFallback: "Sending a question shares the article and recent conversation with the selected model."
                ))
                .font(.callout)
                .foregroundStyle(muted)
            }
            ForEach(history.indices, id: \.self) { index in
                turn(history[index].question, reply: history[index].answer)
            }
            if let submission {
                turn(submission.question, reply: submission.answer, isGenerating: true)
            }
            Color.clear.frame(height: 1).id("articleChatEnd").accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func turn(_ question: String, reply: String, isGenerating: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: question)
                .fontWeight(.semibold)
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(wash, in: RoundedRectangle(cornerRadius: 8))

            if isGenerating && reply.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) == nil {
                waitingReply
            } else {
                let answer = if isGenerating {
                    AttributedString(reply)
                } else {
                    (try? AttributedString(markdown: reply, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(reply)
                }
                Text(answer)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { _ in .discarded })
            }
        }
    }

    private var waitingReply: some View {
        let label = Text(I18N.localized("正在回答", englishFallback: "Generating an answer"))
        let gray = Color(white: 0.60)

        return Group {
            if reduceMotion {
                label.foregroundStyle(gray)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let duration = 1.6
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let phase = elapsed.truncatingRemainder(dividingBy: duration) / duration
                    let center = -0.2 + 1.4 * phase
                    label.foregroundStyle(LinearGradient(
                        colors: [gray, .white, gray],
                        startPoint: UnitPoint(x: center - 0.2, y: 0.5),
                        endPoint: UnitPoint(x: center + 0.2, y: 0.5)
                    ))
                }
            }
        }
        .font(.callout.weight(.medium))
        .accessibilityIdentifier("reader.articleChat.waiting")
    }

    private var composer: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return VStack(alignment: .leading, spacing: 6) {
            if let unavailableMessage {
                Text(unavailableMessage).font(.caption).foregroundStyle(muted)
            } else if let error = session.errors[entryID] {
                Text(error.localizedDescription).font(.caption).foregroundStyle(Color(paperHex: palette.warmHex))
            }

            if #available(macOS 26.0, *) {
                composerControls.glassEffect(.regular.interactive(), in: shape)
            } else {
                composerControls
                    .background(.ultraThinMaterial, in: shape)
                    .overlay { shape.strokeBorder(rule, lineWidth: 0.5).allowsHitTesting(false) }
            }
        }
        .onChange(of: submission?.id) { previous, current in
            if previous != nil && current == nil { composerFocused = true }
        }
    }

    private var composerControls: some View {
        let placeholder = I18N.localized("问一个关于这篇文章的问题", englishFallback: "Ask about this article")

        return HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: draft, prompt: Text(placeholder).foregroundColor(muted), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($composerFocused)
                .onKeyPress(.return, phases: .down) { key in
                    guard key.modifiers.intersection([.shift, .command, .option, .control]).isEmpty,
                          (NSApp.keyWindow?.firstResponder as? any NSTextInputClient)?.hasMarkedText() != true
                    else { return .ignored }
                    sendDraft()
                    return .handled
                }
                .disabled(unavailableMessage != nil || submission != nil)
                .accessibilityIdentifier("reader.articleChat.question")
                .padding(.leading, 8)
                .padding(.vertical, 6)

            if submission != nil {
                let stopTitle = I18N.localized("停止回答", englishFallback: "Stop Reply")
                Button {
                    session.stop(entryID: entryID)
                    composerFocused = true
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 19))
                        .frame(width: 25, height: 26)
                }
                .foregroundStyle(accent)
                .help("\(stopTitle) (Esc)")
                .accessibilityLabel(stopTitle)
            } else {
                let sendTitle = I18N.localized("发送提问", englishFallback: "Send Question")
                Button(action: sendDraft) {
                    Image(systemName: canSend ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 20, weight: canSend ? .semibold : .regular))
                        .frame(width: 25, height: 26)
                }
                .foregroundStyle(canSend ? accent : muted)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help(sendTitle)
                .accessibilityLabel(sendTitle)
                .accessibilityIdentifier("reader.articleChat.send")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func sendDraft() {
        guard canSend else { return }
        session.send(entryID: entryID, animateReply: !reduceMotion, reply: reply)
    }
}
#endif
