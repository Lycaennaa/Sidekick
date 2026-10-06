import Foundation
struct ClearURLsURLCleaner {
    private static let maximumRedirectionDepth = 5
    private static let youtubePlaylistParameter = "list"
    private static let maximumURLBytes = 128 * 1_024

    private let ruleSet: ClearURLsRuleSet

    init(ruleSet: ClearURLsRuleSet) {
        self.ruleSet = ruleSet
    }

    func clean(_ text: String) -> String {
        let start = text.firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
        guard start < text.endIndex else { return text }
        let end = text[..<text.endIndex].lastIndex(where: { !$0.isWhitespace })
            .map(text.index(after:)) ?? start
        let candidate = String(text[start..<end])
        guard candidate.utf8.count <= Self.maximumURLBytes else { return text }
        let cleaned = cleanURL(candidate, redirectionDepth: 0)
        guard cleaned != candidate else { return text }
        return String(text[..<start]) + cleaned + String(text[end...])
    }

    private func cleanURL(_ input: String, redirectionDepth: Int) -> String {
        guard let url = URL(string: input), isWebURL(url) else { return input }

        if let globalProvider = ruleSet.globalProvider,
           matches(globalProvider.urlPattern, in: input),
           matchesAny(globalProvider.exceptions, in: input) {
            return input
        }

        let matchingProviders = ruleSet.providers.filter {
            matches($0.urlPattern, in: input)
        }
        let eligibleProviders = matchingProviders.filter {
            !matchesAny($0.exceptions, in: input)
        }

        if redirectionDepth < Self.maximumRedirectionDepth,
           let redirectedURL = redirectedURL(
               from: input,
               providers: eligibleProviders
           ) {
            return cleanURL(redirectedURL, redirectionDepth: redirectionDepth + 1)
        }

        var cleaned = input
        for provider in eligibleProviders {
            cleaned = applyRawRules(provider.rawRules, to: cleaned)
        }

        if eligibleProviders.contains(where: \.completeProvider) {
            return removeQuery(from: cleaned, removing: { _ in true })
        }

        var parameterRules: [NSRegularExpression] = []
        if let globalProvider = ruleSet.globalProvider {
            parameterRules.append(contentsOf: globalProvider.rules)
            parameterRules.append(contentsOf: globalProvider.referralMarketing)
        }
        for provider in eligibleProviders {
            parameterRules.append(contentsOf: provider.rules)
            parameterRules.append(contentsOf: provider.referralMarketing)
        }
        guard !parameterRules.isEmpty else { return cleaned }

        let preserveYouTubePlaylist = isYouTube(url)
        return removeQuery(from: cleaned) { parameterName in
            let decodedParameterName = parameterName.removingPercentEncoding ?? parameterName
            return preserveYouTubePlaylist
                && decodedParameterName.caseInsensitiveCompare(Self.youtubePlaylistParameter) == .orderedSame
                ? false
                : matchesAnyParameterRule(parameterRules, parameterName: parameterName)
        }
    }

    private func redirectedURL(
        from input: String,
        providers: [ClearURLsRuleSet.Provider]
    ) -> String? {
        let sortedProviders = providers
            .filter { !$0.redirections.isEmpty }
            .sorted {
                if $0.forceRedirection != $1.forceRedirection {
                    return $0.forceRedirection
                }
                if $0.patternLength != $1.patternLength {
                    return $0.patternLength > $1.patternLength
                }
                return $0.name < $1.name
            }

        for provider in sortedProviders {
            for redirection in provider.redirections {
                let range = NSRange(location: 0, length: (input as NSString).length)
                guard let match = redirection.firstMatch(in: input, range: range),
                      match.numberOfRanges > 1 else {
                    continue
                }
                let targetRange = match.range(at: 1)
                guard targetRange.location != NSNotFound else { continue }
                let captured = (input as NSString).substring(with: targetRange)
                let target = captured.removingPercentEncoding ?? captured
                guard let targetURL = URL(string: target), isWebURL(targetURL), target != input else {
                    continue
                }
                return target
            }
        }
        return nil
    }

    private func applyRawRules(
        _ rules: [NSRegularExpression],
        to input: String
    ) -> String {
        rules.reduce(input) { value, rule in
            let range = NSRange(location: 0, length: (value as NSString).length)
            return rule.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: ""
            )
        }
    }

    private func removeQuery(
        from input: String,
        removing shouldRemove: (String) -> Bool
    ) -> String {
        guard let queryDelimiter = input.firstIndex(of: "?") else { return input }
        let queryStart = input.index(after: queryDelimiter)
        let queryEnd = input[queryStart...].firstIndex(of: "#") ?? input.endIndex
        let query = input[queryStart..<queryEnd]
        let parameters = query.split(separator: "&", omittingEmptySubsequences: false)

        var removedParameter = false
        var retainedParameters: [String] = []
        retainedParameters.reserveCapacity(parameters.count)
        for parameter in parameters {
            let equals = parameter.firstIndex(of: "=") ?? parameter.endIndex
            let name = String(parameter[..<equals])
            if shouldRemove(name) {
                removedParameter = true
            } else {
                retainedParameters.append(String(parameter))
            }
        }
        guard removedParameter else { return input }

        let base = String(input[..<queryDelimiter])
        let fragment = String(input[queryEnd...])
        let retainedQuery = retainedParameters.joined(separator: "&")
        return base
            + (retainedQuery.isEmpty ? "" : "?" + retainedQuery)
            + fragment
    }

    private func matchesAnyParameterRule(
        _ rules: [NSRegularExpression],
        parameterName: String
    ) -> Bool {
        let decodedName = parameterName.removingPercentEncoding ?? parameterName
        let candidates = [
            parameterName,
            decodedName,
            "?" + parameterName,
            "&" + parameterName,
            "?" + decodedName,
            "&" + decodedName
        ]
        return rules.contains { rule in
            candidates.contains { candidate in matches(rule, in: candidate) }
        }
    }

    private func matchesAny(
        _ expressions: [NSRegularExpression],
        in value: String
    ) -> Bool {
        expressions.contains { matches($0, in: value) }
    }

    private func matches(_ expression: NSRegularExpression, in value: String) -> Bool {
        expression.firstMatch(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        ) != nil
    }

    private func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
    }
}
