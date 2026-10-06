import Foundation

enum TemporaryVolumeDuration {
    static let maximumMinutes: Double = 7 * 24 * 60
    static let maximumInterval: TimeInterval = maximumMinutes * 60

    static func isValidInterval(_ interval: TimeInterval) -> Bool {
        interval.isFinite && interval > 0 && interval <= maximumInterval
    }

    static func interval(from input: String) -> TimeInterval? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let minutes = Double(text) {
            return boundedInterval(minutes: minutes)
        }
        return compoundInterval(from: text)
    }

    private struct DurationToken {
        let amount: Double
        let multiplier: Double
        let hasUnit: Bool
    }

    private static func compoundInterval(from text: String) -> TimeInterval? {
        var cursor = text.startIndex
        var totalMinutes = 0.0
        var tokenCount = 0
        var hasUnit = false

        while cursor < text.endIndex {
            skipWhitespace(in: text, at: &cursor)
            guard cursor < text.endIndex else { break }
            guard let token = nextToken(in: text, at: &cursor),
                  canAppend(token, tokenCount: tokenCount, cursor: cursor, endIndex: text.endIndex) else {
                return nil
            }
            totalMinutes += token.amount * token.multiplier
            guard isValidInterval(totalMinutes * 60) else { return nil }
            hasUnit = token.hasUnit
            tokenCount += 1
        }

        return parsedInterval(totalMinutes: totalMinutes, tokenCount: tokenCount, hasUnit: hasUnit)
    }

    private static func skipWhitespace(in text: String, at cursor: inout String.Index) {
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
    }

    private static func canAppend(
        _ token: DurationToken,
        tokenCount: Int,
        cursor: String.Index,
        endIndex: String.Index
    ) -> Bool {
        guard tokenCount == 0 else { return token.hasUnit }
        return token.hasUnit || cursor == endIndex
    }

    private static func parsedInterval(
        totalMinutes: Double,
        tokenCount: Int,
        hasUnit: Bool
    ) -> TimeInterval? {
        guard tokenCount > 0, hasUnit || tokenCount == 1 else { return nil }
        return totalMinutes * 60
    }

    private static func nextToken(
        in text: String,
        at cursor: inout String.Index
    ) -> DurationToken? {
        guard let amount = parseAmount(in: text, at: &cursor) else { return nil }
        let (multiplier, hasUnit) = parseUnit(in: text, at: &cursor)
        return DurationToken(amount: amount, multiplier: multiplier, hasUnit: hasUnit)
    }

    private static func parseAmount(in text: String, at cursor: inout String.Index) -> Double? {
        let numberStart = cursor
        var hasDigit = false
        var hasDecimalPoint = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isNumber {
                hasDigit = true
                cursor = text.index(after: cursor)
            } else if character == ".", !hasDecimalPoint {
                hasDecimalPoint = true
                cursor = text.index(after: cursor)
            } else {
                break
            }
        }
        guard hasDigit else { return nil }
        return Double(text[numberStart..<cursor])
    }

    private static func parseUnit(
        in text: String,
        at cursor: inout String.Index
    ) -> (multiplier: Double, hasUnit: Bool) {
        skipWhitespace(in: text, at: &cursor)
        guard cursor < text.endIndex else { return (1, false) }
        let multiplier: Double
        switch text[cursor].lowercased() {
        case "s":
            multiplier = 1.0 / 60.0
        case "m":
            multiplier = 1
        case "h":
            multiplier = 60
        case "d":
            multiplier = 24 * 60
        default:
            return (1, false)
        }
        cursor = text.index(after: cursor)
        return (multiplier, true)
    }

    static func label(for interval: TimeInterval) -> String {
        let minutes = interval / 60
        if minutes >= 60, minutes.truncatingRemainder(dividingBy: 60) == 0 {
            let hours = Int(minutes / 60)
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        if minutes.rounded() == minutes {
            let value = Int(minutes)
            return "\(value) minute\(value == 1 ? "" : "s")"
        }
        return "\(minutes.formatted()) minutes"
    }

    private static func boundedInterval(minutes: Double) -> TimeInterval? {
        let interval = minutes * 60
        return isValidInterval(interval) ? interval : nil
    }
}
