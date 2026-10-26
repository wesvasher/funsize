import SwiftUI

/// Settings › Help: the articles on the left, the chosen one on the right.
struct HelpSettingsView: View {
    /// The article shown. Other parts of the app set this to open Help at an article.
    @AppStorage(HelpSettingsView.articleKey) private var articleID = ""
    @State private var search = ""

    static let articleKey = "helpArticle"

    private var shown: [HelpArticle] { HelpLibrary.articles.filter { $0.matches(search) } }
    private var article: HelpArticle? { HelpLibrary.article(articleID) ?? HelpLibrary.articles.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search Help", text: $search, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                List(selection: Binding(get: { article?.id }, set: { if let id = $0 { articleID = id } })) {
                    ForEach(HelpLibrary.categories(shown), id: \.name) { category in
                        Section(category.name) {
                            ForEach(category.articles) { article in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(article.title)
                                    if !article.summary.isEmpty {
                                        Text(article.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                                .tag(article.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .overlay {
                    if shown.isEmpty { ContentUnavailableView.search(text: search) }
                }
            }
            .frame(width: 240)

            Divider()

            if let article {
                HelpArticleView(article: article)
                    .id(article.id)
            } else {
                ContentUnavailableView("No Help Articles", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // `help:` links open another article.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "help" else { return .systemAction }
            articleID = url.absoluteString.replacingOccurrences(of: "help:", with: "")
            return .handled
        })
    }
}

/// One article, rendered from its Markdown blocks.
struct HelpArticleView: View {
    let article: HelpArticle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(article.title)
                    .font(.title.bold())
                if !article.summary.isEmpty {
                    Text(article.summary)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level == 3 ? 4 : 10)
        case .paragraph(let text):
            Text(Self.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            list(items) { _ in "•" }
        case .numbered(let items):
            list(items) { "\($0 + 1)." }
        case .note(let text):
            Label {
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        case .table(let rows):
            table(rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func list(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(Self.inline(item))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(Self.inline(column < row.count ? row[column] : ""))
                            .font(index == 0 ? .callout.weight(.semibold) : .callout)
                            .foregroundStyle(index == 0 ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index == 0 { Divider() }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Bold, italics, code and links within a block.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
