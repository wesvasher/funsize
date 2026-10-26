import Foundation
import Testing
@testable import SwiftCut

struct HelpTests {
    @Test func readsFrontMatterAndBlocks() {
        let article = HelpArticle(id: "sample", text: """
        ---
        title: Sample
        category: Sound
        summary: A test.
        order: 2
        ---

        ## Heading

        One line
        and the next.

        - First
        - Second
          continued

        1. Step one
        2. Step two

        > A note.

        | A | B |
        |---|---|
        | 1 | 2 |

        ---
        """)
        #expect(article.title == "Sample" && article.category == "Sound" && article.summary == "A test." && article.order == 2)
        #expect(article.blocks == [
            .heading(level: 2, text: "Heading"),
            .paragraph("One line and the next."),
            .bullets(["First", "Second continued"]),
            .numbered(["Step one", "Step two"]),
            .note("A note."),
            .table([["A", "B"], ["1", "2"]]),
            .rule,
        ])
    }

    @Test func withoutFrontMatterTheFileNameIsTheTitle() {
        let article = HelpArticle(id: "plain", text: "Just text.")
        #expect(article.title == "plain" && article.blocks == [.paragraph("Just text.")])
    }

    @Test func bundledArticlesLoadAndTheirLinksWork() throws {
        let articles = HelpLibrary.articles
        #expect(articles.contains { $0.id == "listening-level" })
        for article in articles {
            #expect(!article.blocks.isEmpty, "\(article.id) is empty")
            // Every help: link names an article.
            let links = article.body.matches(of: /\(help:([a-z0-9-]+)\)/).map { String($0.1) }
            for link in links {
                #expect(HelpLibrary.article(link) != nil, "\(article.id) links to missing \(link)")
            }
        }
    }

    @Test func searchFindsTitlesAndText() throws {
        let article = try #require(HelpLibrary.article("listening-level"))
        #expect(article.matches("listening"))
        #expect(article.matches("headphones"))
        #expect(!article.matches("deinterlace"))
    }
}
