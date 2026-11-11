#if os(macOS)
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct KeywordMuteSheet: View {
    struct Request: Identifiable {
        let id = UUID()
        let scope: KeywordMuteScope
        let title: String
        let showsHiddenArticles: Bool
    }

    @ObservedObject var store: AppStore
    let request: Request
    let onSave: () -> Void
    let onOpenArticle: (EntryListItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var originalRule: KeywordMuteRule?
    @State private var keywords = ""
    @State private var isEnabled = true
    @State private var articles: [EntryListItem] = []
    @State private var previewedRule: KeywordMuteRule?
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var saveFailed = false

    private let previewLimit = 8
    private let pageSize = 50

    private var draftRule: KeywordMuteRule {
        KeywordMuteRule(keywords: keywords.components(separatedBy: .newlines), isEnabled: isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(I18N.localized(request.showsHiddenArticles ? "查看已隐藏文章" : "关键词静音"))
                .font(.headline)
            Text(request.title)
                .foregroundStyle(.secondary)
            if request.showsHiddenArticles {
                hiddenArticles
                    .task(id: store.timelineRevision) { await loadHiddenArticles(reset: true) }
            } else if originalRule != nil {
                editor
                    .disabled(isSaving)
            } else if loadFailed {
                Text(I18N.localized("无法载入关键词静音规则。"))
            } else {
                ProgressView()
            }
            Divider()
            HStack {
                Spacer()
                if request.showsHiddenArticles {
                    Button(I18N.localized("关闭")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(I18N.localized("取消")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                    Button(I18N.localized("保存")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(originalRule == nil || originalRule == draftRule || isSaving)
                }
            }
        }
        .padding(20)
        .frame(width: 490)
        .interactiveDismissDisabled(isSaving)
        .task {
            guard !request.showsHiddenArticles else { return }
            do {
                let rule = try await store.keywordMuteRule(for: request.scope)
                keywords = rule.keywords.joined(separator: "\n")
                isEnabled = rule.isEnabled
                originalRule = rule
            } catch {
                loadFailed = true
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18N.localized("每行填写一个关键词。标题或订阅摘要包含任意关键词时，文章将被隐藏。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $keywords)
                .font(.body)
                .frame(height: 86)
                .border(.quaternary)
                .accessibilityLabel(I18N.localized("静音关键词"))
            Toggle(I18N.localized("启用关键词静音"), isOn: $isEnabled)
            Text(I18N.localized("匹配预览"))
                .font(.subheadline.weight(.semibold))
            Group {
                if draftRule.keywords.isEmpty {
                    Text(I18N.localized("输入关键词后可预览匹配的文章。"))
                        .foregroundStyle(.secondary)
                } else if previewedRule != draftRule {
                    ProgressView()
                } else if loadFailed {
                    Text(I18N.localized("无法载入文章。"))
                } else if articles.isEmpty {
                    Text(I18N.localized("没有匹配的文章。"))
                        .foregroundStyle(.secondary)
                } else {
                    articleList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 170, alignment: .top)
            if saveFailed {
                Text(I18N.localized("无法保存关键词静音规则。"))
                    .foregroundStyle(.red)
            }
        }
        .task(id: draftRule) { await preview(draftRule) }
    }

    private var hiddenArticles: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !articles.isEmpty {
                articleList
            } else if !isLoading && !loadFailed {
                Text(I18N.localized("这个范围没有已隐藏的文章。"))
                    .foregroundStyle(.secondary)
            }
            if isLoading {
                ProgressView()
            } else if loadFailed {
                Text(I18N.localized("无法载入文章。"))
                Button(I18N.localized("重试")) {
                    Task { await loadHiddenArticles(reset: articles.isEmpty) }
                }
            } else if hasMore {
                Button(I18N.localized("加载更多")) {
                    Task { await loadHiddenArticles(reset: false) }
                }
            }
        }
    }

    private var articleList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(articles) { article in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(article.title).font(.callout.weight(.medium))
                            Text(article.sourceTitle).font(.caption).foregroundStyle(.secondary)
                            if !article.summaryPreview.isEmpty {
                                Text(article.summaryPreview).font(.caption).lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if request.showsHiddenArticles {
                            Button(I18N.localized("打开文章")) {
                                dismiss()
                                onOpenArticle(article)
                            }
                        }
                    }
                    Divider()
                }
            }
        }
        .frame(height: request.showsHiddenArticles ? 300 : 170)
    }

    private func preview(_ rule: KeywordMuteRule) async {
        guard !rule.keywords.isEmpty else {
            articles = []
            previewedRule = rule
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(220))
            let matches = try await store.keywordMuteArticles(in: request.scope, previewRule: rule, limit: previewLimit)
            guard !Task.isCancelled, draftRule == rule else { return }
            articles = matches
            loadFailed = false
            previewedRule = rule
        } catch {
            guard !Task.isCancelled, draftRule == rule else { return }
            loadFailed = true
            previewedRule = rule
        }
    }

    private func loadHiddenArticles(reset: Bool) async {
        if reset {
            articles = []
            hasMore = false
        } else if isLoading {
            return
        }
        let offset = articles.count
        let revision = store.timelineRevision
        isLoading = true
        loadFailed = false
        do {
            let page = try await store.keywordMuteArticles(in: request.scope, limit: pageSize + 1, offset: offset)
            guard !Task.isCancelled, revision == store.timelineRevision else { return }
            let loadedIDs = Set(articles.map(\.id))
            articles.append(contentsOf: page.prefix(pageSize).filter { !loadedIDs.contains($0.id) })
            hasMore = page.count > pageSize
        } catch {
            guard !Task.isCancelled, revision == store.timelineRevision else { return }
            loadFailed = true
        }
        isLoading = false
    }

    private func save() {
        guard !isSaving else { return }
        let rule = draftRule
        isSaving = true
        saveFailed = false
        Task {
            do {
                try await store.saveKeywordMuteRule(rule, for: request.scope)
                onSave()
                dismiss()
            } catch {
                saveFailed = true
                isSaving = false
            }
        }
    }
}
#endif
