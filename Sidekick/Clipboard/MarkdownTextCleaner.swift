import Foundation
import Markdown

nonisolated enum MarkdownTextCleaner {
    static func clean(_ markdown: String) -> String {
        let frontMatter = FrontMatter.extract(from: markdown)
        let body = frontMatter?.body ?? markdown
        var visitor = PlainTextVisitor(markdown: body)
        let cleanedBody = visitor.visit(Document(parsing: body))
            .trimmingCharacters(in: .newlines)
        guard let frontMatter else { return cleanedBody }
        guard !cleanedBody.isEmpty else { return frontMatter.raw }
        return frontMatter.raw + "\n\n" + cleanedBody
    }

    nonisolated private struct FrontMatter {
        let raw: String
        let body: String

        static func extract(from markdown: String) -> Self? {
            guard let firstNewline = markdown.firstIndex(of: "\n") else { return nil }
            let firstLine = markdown[..<firstNewline]
                .trimmingCharacters(in: .newlines)
            guard firstLine == "---" else { return nil }

            let metadataStart = markdown.index(after: firstNewline)
            var lineStart = metadataStart
            while lineStart < markdown.endIndex {
                let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
                let line = markdown[lineStart..<lineEnd]
                    .trimmingCharacters(in: .newlines)
                if line == "---" || line == "..." {
                    guard Self.isYAMLMetadata(markdown[metadataStart..<lineStart]) else {
                        return nil
                    }
                    let bodyStart = lineEnd == markdown.endIndex
                        ? lineEnd
                        : markdown.index(after: lineEnd)
                    return Self(
                        raw: String(markdown[..<lineEnd]),
                        body: String(markdown[bodyStart...])
                    )
                }
                guard lineEnd < markdown.endIndex else { break }
                lineStart = markdown.index(after: lineEnd)
            }
            return nil
        }

        private static func isYAMLMetadata(_ metadata: Substring) -> Bool {
            var topLevelKeys = Set<String>()
            var hasTopLevelMapping = false
            for rawLine in metadata.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine).trimmingCharacters(in: .newlines)
                let content = line.drop(while: { $0 == " " || $0 == "\t" })
                guard !content.isEmpty, !content.hasPrefix("#") else { continue }
                if line.count != content.count {
                    guard hasTopLevelMapping else { return false }
                    continue
                }
                guard let colon = content.firstIndex(of: ":") else { return false }
                let valueStart = content.index(after: colon)
                guard valueStart == content.endIndex || content[valueStart].isWhitespace else {
                    return false
                }
                let rawKey = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
                let key: String
                if (rawKey.hasPrefix("\"") && rawKey.hasSuffix("\""))
                    || (rawKey.hasPrefix("'") && rawKey.hasSuffix("'")) {
                    key = String(rawKey.dropFirst().dropLast())
                } else {
                    guard !rawKey.isEmpty,
                          rawKey.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else {
                        return false
                    }
                    key = rawKey
                }
                guard !key.isEmpty else { return false }
                hasTopLevelMapping = true
                topLevelKeys.insert(key)
            }
            return topLevelKeys.contains("name") && topLevelKeys.contains("description")
        }
    }
}

nonisolated private struct PlainTextVisitor: MarkupVisitor {
    private let sourceLines: [Substring]

    init(markdown: String) {
        sourceLines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        joinedChildren(of: markup, separator: "")
    }

    mutating func visitDocument(_ document: Document) -> String {
        joinedBlocks(in: document, defaultSeparator: "\n\n")
    }
    mutating func visitHeading(_ heading: Heading) -> String {
        let text = joinedChildren(of: heading, separator: "")
        guard !text.isEmpty else { return "" }
        return text.hasSuffix(":") ? text : "\(text):"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        joinedBlocks(in: blockQuote, defaultSeparator: "\n\n")
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        codeBlock.code.hasSuffix("\n") ? String(codeBlock.code.dropLast()) : codeBlock.code
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        let text = visibleText(in: html.rawHTML)
        var visitor = PlainTextVisitor(markdown: text)
        return visitor.visit(Document(parsing: text))
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        joinedBlocks(in: listItem, defaultSeparator: "\n")
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        joinedBlocks(in: orderedList, defaultSeparator: "\n")
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        joinedBlocks(in: unorderedList, defaultSeparator: "\n")
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        ""
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        inlineCode.code
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        visibleText(in: inlineHTML.rawHTML)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitText(_ text: Text) -> String {
        text.string
    }

    mutating func visitTable(_ table: Table) -> String {
        joinedChildren(of: table, separator: "\n")
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        joinedChildren(of: tableHead, separator: "\t", omittingEmpty: false)
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        joinedChildren(of: tableBody, separator: "\n", omittingEmpty: false)
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        joinedChildren(of: tableRow, separator: "\t", omittingEmpty: false)
    }

    private mutating func joinedChildren(
        of markup: Markup,
        separator: String,
        omittingEmpty: Bool = true
    ) -> String {
        var parts: [String] = []
        parts.reserveCapacity(markup.childCount)
        for child in markup.children {
            let text = visit(child)
            if !omittingEmpty || !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: separator)
    }

    private mutating func joinedBlocks(
        in markup: Markup,
        defaultSeparator: String
    ) -> String {
        var parts: [String] = []
        parts.reserveCapacity(markup.childCount * 2)
        var previous: Markup?

        for child in markup.children {
            let text = visit(child)
            guard !text.isEmpty else { continue }
            if let previous {
                parts.append(blockSeparator(from: previous, to: child, default: defaultSeparator))
            }
            parts.append(text)
            previous = child
        }
        return parts.joined()
    }

    private func blockSeparator(from previous: Markup, to current: Markup, default: String) -> String {
        guard let previousRange = previous.range, let currentRange = current.range else {
            return `default`
        }
        let firstLine = previousRange.upperBound.column == 1
            ? previousRange.upperBound.line
            : previousRange.upperBound.line + 1
        let lastLine = currentRange.lowerBound.line - 1
        guard firstLine <= lastLine else { return "\n" }

        for lineNumber in firstLine...lastLine where sourceLines.indices.contains(lineNumber - 1) {
            if isBlankMarkdownLine(sourceLines[lineNumber - 1]) {
                return "\n\n"
            }
        }
        return "\n"
    }

    private func isBlankMarkdownLine(_ line: Substring) -> Bool {
        var content = line[...]
        while true {
            content = content.drop(while: { $0 == " " || $0 == "\t" })
            guard content.first == ">" else { break }
            content = content.dropFirst()
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func visibleText(in html: String) -> String {
        var output = ""
        var index = html.startIndex

        while index < html.endIndex {
            if html[index...].hasPrefix("<!--") {
                guard let end = html[index...].range(of: "-->") else { break }
                index = end.upperBound
            } else if html[index] == "<", isHTMLTagStart(in: html, at: index) {
                let start = index
                index = html.index(after: index)
                var quote: Character?
                var foundEnd = false
                while index < html.endIndex {
                    let character = html[index]
                    if let activeQuote = quote {
                        if character == activeQuote { quote = nil }
                    } else if character == "\"" || character == "'" {
                        quote = character
                    } else if character == ">" {
                        index = html.index(after: index)
                        foundEnd = true
                        break
                    }
                    index = html.index(after: index)
                }
                if !foundEnd {
                    output.append("<")
                    index = html.index(after: start)
                }
            } else {
                output.append(html[index])
                index = html.index(after: index)
            }
        }
        return output.trimmingCharacters(in: .newlines)
    }

    private func isHTMLTagStart(in html: String, at index: String.Index) -> Bool {
        var next = html.index(after: index)
        guard next < html.endIndex else { return false }
        if html[next] == "/" {
            next = html.index(after: next)
            guard next < html.endIndex else { return false }
        }
        let scalar = html[next].unicodeScalars.first
        let isASCIILetter = html[next].unicodeScalars.count == 1
            && scalar.map { (65...90).contains($0.value) || (97...122).contains($0.value) } == true
        return isASCIILetter || html[next] == "!" || html[next] == "?"
    }

}
