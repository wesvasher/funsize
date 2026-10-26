import Foundation

/// A Help article: a Markdown file in `Resources/Help`, with a few lines of front matter:
///
///     ---
///     title: Setting your listening level
///     category: Sound
///     summary: One line for the list.
///     order: 1
///     ---
///
/// To add an article, drop a new `.md` file in that folder. Link to another article
/// with `[text](help:file-name)`.
nonisolated struct HelpArticle: Identifiable, Hashable, Sendable {
    /// The file name without `.md`.
    var id: String
    var title: String
    var category: String
    var summary: String
    var order: Int
    var body: String

    var blocks: [HelpBlock] { HelpBlock.parse(body) }

    init(id: String, text: String) {
        self.id = id
        var fields: [String: String] = [:]
        var body = text
        let lines = text.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        title = fields["title"] ?? id
        category = fields["category"] ?? "General"
        summary = fields["summary"] ?? ""
        order = fields["order"].flatMap(Int.init) ?? 100
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the article matches a search (title, summary or text).
    func matches(_ search: String) -> Bool {
        let search = search.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return true }
        return [title, summary, body].contains { $0.localizedStandardContains(search) }
    }
}

/// The bundled articles.
nonisolated enum HelpLibrary {
    static let articles: [HelpArticle] = load(from: Bundle.main.url(forResource: "Help", withExtension: nil))

    static func load(from folder: URL?) -> [HelpArticle] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map {
                    HelpArticle(id: url.deletingPathExtension().lastPathComponent, text: $0)
                }
            }
            .sorted { ($0.category, $0.order, $0.title) < ($1.category, $1.order, $1.title) }
    }

    static func article(_ id: String) -> HelpArticle? {
        articles.first { $0.id == id }
    }

    /// Articles grouped by category, in order.
    static func categories(_ articles: [HelpArticle]) -> [(name: String, articles: [HelpArticle])] {
        var names: [String] = []
        for article in articles where !names.contains(article.category) { names.append(article.category) }
        return names.map { name in (name, articles.filter { $0.category == name }) }
    }
}

/// A block of an article's Markdown: the subset Help needs. Text inside blocks keeps
/// its inline Markdown (bold, italics, code, links).
nonisolated enum HelpBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    /// A highlighted note (lines starting with `>`).
    case note(String)
    /// The first row is the header.
    case table([[String]])
    case rule

    static func parse(_ markdown: String) -> [HelpBlock] {
        var blocks: [HelpBlock] = []
        var paragraph: [String] = []
        var list: (numbered: Bool, items: [String])?
        var note: [String] = []
        var table: [[String]] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if let current = list { blocks.append(current.numbered ? .numbered(current.items) : .bullets(current.items)); list = nil }
            if !note.isEmpty { blocks.append(.note(note.joined(separator: " "))); note = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }

            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(level: min(level, 3), text: line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // Skip the |---|---| line under the header.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue }
                table.append(cells)
            } else if line.hasPrefix(">") {
                if note.isEmpty { flush() }
                note.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if let item = bullet(line) {
                if list?.numbered != false { flush(); list = (false, []) }
                list?.items.append(item)
            } else if let item = numberedItem(line) {
                if list?.numbered != true { flush(); list = (true, []) }
                list?.items.append(item)
            } else if var current = list, !current.items.isEmpty, raw.hasPrefix("  ") {
                // An indented line continues the list item above.
                current.items[current.items.count - 1] += " " + line
                list = current
            } else {
                if list != nil || !note.isEmpty || !table.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func bullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        return String(line.dropFirst(2))
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }
}
