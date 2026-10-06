import XCTest

final class MarkdownTextCleanerTests: XCTestCase {
    func testCleanerPreservesReadableTextAndLineStructure() {
        let markdown = """
        # Heading

        > **Bold** and [link](https://example.com)
        - first
        1. second
        - [x] done

        ---

        ```swift
        let value = "**literal**"
        ```

        `code`, ~~strike~~, ![alt](image.png), and <em>HTML</em>.
        """

        let cleaned = MarkdownTextCleaner.clean(markdown)
        let expected = """
            Heading:

            Bold and link
            first
            second
            done

            let value = "**literal**"

            code, strike, alt, and HTML.
            """
        XCTAssertEqual(cleaned, expected, "actual: \(cleaned.debugDescription)")
    }

    func testCleanerConvertsAllMarkdownHeadersToColonLabels() {
        let markdown = "# First\n\n## Second\n\n### Third:"

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "First:\n\nSecond:\n\nThird:"
        )
    }
    func testCleanerHandlesIndentedCodeQuotedFencesAndReferenceLinks() {
        let markdown = """
            - **literal list marker**

        > ```
        > **literal fenced content**
        > ```

        Read [the docs][docs].

        [docs]: https://example.com
        """

        let cleaned = MarkdownTextCleaner.clean(markdown)
        let expected = """
            - **literal list marker**

            **literal fenced content**

            Read the docs.
            """
        XCTAssertEqual(cleaned, expected, "actual: \(cleaned.debugDescription)")
    }

    func testCleanerDoesNotInterpretMarkdownInsideOrdinaryFence() {
        let markdown = """
        ```html
        > literal comparison
        <!-- literal comment -->
        ```
        """

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "> literal comparison\n<!-- literal comment -->"
        )
    }

    func testCleanerResolvesReferenceDefinedInsideBlockQuote() {
        let markdown = """
        > [docs]: https://example.com

        Read [the docs][docs].
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "Read the docs.")
    }

    func testCleanerStripsOnlyEnclosingQuoteFromQuotedFence() {
        let markdown = """
        > ```
        > > literal quote
        > ```
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "> literal quote")
    }

    func testCleanerIgnoresReferenceDefinitionsInsideFence() {
        let markdown = """
        ```
        [docs]: literal code
        ```

        Read [the docs][docs].
        """

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "[docs]: literal code\n\nRead [the docs][docs]."
        )
    }

    func testCleanerRemovesMultilineCommentsAndSetextMarker() {
        let markdown = """
        Heading
        -

        <!--
        hidden
        -->
        Visible
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "Heading:\n\nVisible")
    }

    func testCleanerPreservesSkillFrontmatter() {
        let markdown = """
        ---
        name: example
        description: Keep **this** metadata
        ---

        # Instructions

        Use **bold**.
        """

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "---\nname: example\ndescription: Keep **this** metadata\n---\n\nInstructions:\n\nUse bold."
        )
    }

    func testCleanerDoesNotTreatIndentedThematicBreaksAsFrontmatter() {
        let markdown = "  ---\n# Heading\n  ---\n\n**Body**"

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "Heading:\n\nBody"
        )
    }

    func testCleanerDoesNotTreatFenceContentAsFrontmatter() {
        let markdown = "---\n```swift\nlet value = 1\n---\n```\nAfter"

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "let value = 1\n---\nAfter"
        )
    }

    func testCleanerDoesNotTreatURLAsFrontmatter() {
        let markdown = "---\nhttps://example.com\n---\n\n# Heading"

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "https://example.com:\n\nHeading:"
        )
    }

    func testCleanerPreservesMultilineSkillFrontmatter() {
        let markdown = """
        ---
        name: example
        description: |
          First line.
          Second line.
        extra: value
        ---

        # Body
        """

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "---\nname: example\ndescription: |\n  First line.\n  Second line.\nextra: value\n---\n\nBody:"
        )
    }

    func testCleanerPreservesQuotedAndAdditionalSkillFrontmatter() {
        let markdown = """
        ---
        "name": ponytail
        'description': Writing code guidelines.
        extra-field: value
        ...

        # Body
        """

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "---\n\"name\": ponytail\n'description': Writing code guidelines.\nextra-field: value\n...\n\nBody:"
        )
    }

    func testCleanerDoesNotTreatUnseparatedColonAsFrontmatter() {
        let markdown = "---\nname:pony\ndescription: text\n---\n# Body"
        let cleaned = MarkdownTextCleaner.clean(markdown)

        XCTAssertFalse(cleaned.hasPrefix("---\n"))
    }
    func testCleanerPreservesIndentedCodeThatLooksLikeFence() {
        let markdown = """
            ```
            literal
            ```
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "```\nliteral\n```")
    }

    func testCleanerPreservesHTMLLiteralsInsideCode() {
        let markdown = """
        Inline `<!-- literal -->` and `<em>literal</em>`.

            <!-- indented literal -->
        """

        XCTAssertEqual(
            MarkdownTextCleaner.clean(markdown),
            "Inline <!-- literal --> and <em>literal</em>.\n\n<!-- indented literal -->"
        )
    }

    func testCleanerRemovesHTMLTagsWithQuotedAngleBrackets() {
        let markdown = #"Before <span title="1 > 0">visible</span> after."#

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "Before visible after.")
    }

    func testCleanerPreservesTextAndDecodesEntitiesInsideHTMLBlocks() {
        let markdown = """
        <div>
        1 < 2 &amp; 3 > 2
        </div>
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "1 < 2 & 3 > 2")
    }

    func testCleanerPreservesNonHTMLAngleBracketTextInsideHTMLBlocks() {
        let markdown = """
        <div>
        Use <π> symbol
        </div>
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "Use <π> symbol")
    }

    func testCleanerIgnoresFencesInsideMultilineComment() {
        let markdown = """
        <!--
        ```
        hidden
        ```
        -->
        Visible
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "Visible")
    }

    func testCleanerPreservesParagraphBreaksInsideBlockQuotes() {
        let markdown = """
        > First
        >
        > Second
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "First\n\nSecond")
    }

    func testCleanerConvertsPipeTableToReadableColumns() {
        let markdown = """
        | Name | Value |
        | --- | --- |
        | **One** | [Two](https://example.com) |
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "Name\tValue\nOne\tTwo")
    }

    func testCleanerPreservesEmptyTableColumns() {
        let markdown = """
        | First |  | Third |
        | --- | --- | --- |
        | One |  | Three |
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "First\t\tThird\nOne\t\tThree")
    }

    func testCleanerDoesNotAddBlankRowsForHeaderOnlyTables() {
        let markdown = """
        | First | Second |
        | --- | --- |

        After
        """

        XCTAssertEqual(MarkdownTextCleaner.clean(markdown), "First\tSecond\n\nAfter")
    }
}
