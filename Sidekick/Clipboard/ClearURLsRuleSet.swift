import Foundation

enum ClearURLsRuleSetError: Error {
    case bundledResourceNotFound
    case invalidJSON
    case invalidPattern(provider: String, field: String, pattern: String)
}

private enum ClearURLsRuleSetDefinitionCodingKeys: String, CodingKey {
    case urlPattern
    case completeProvider
    case rules
    case referralMarketing
    case rawRules
    case exceptions
    case redirections
    case forceRedirection
}

struct ClearURLsRuleSet {
    struct Provider {
        let name: String
        let urlPattern: NSRegularExpression
        let completeProvider: Bool
        let rules: [NSRegularExpression]
        let referralMarketing: [NSRegularExpression]
        let rawRules: [NSRegularExpression]
        let exceptions: [NSRegularExpression]
        let redirections: [NSRegularExpression]
        let forceRedirection: Bool
        let patternLength: Int

        init(name: String, definition: Definition) throws {
            self.name = name
            do {
                urlPattern = try NSRegularExpression(
                    pattern: definition.urlPattern,
                    options: [.caseInsensitive]
                )
            } catch {
                throw ClearURLsRuleSetError.invalidPattern(
                    provider: name,
                    field: "urlPattern",
                    pattern: definition.urlPattern
                )
            }
            completeProvider = definition.completeProvider
            rules = try Self.compile(
                definition.rules,
                provider: name,
                field: "rules"
            )
            referralMarketing = try Self.compile(
                definition.referralMarketing,
                provider: name,
                field: "referralMarketing"
            )
            rawRules = try Self.compile(
                definition.rawRules,
                provider: name,
                field: "rawRules"
            )
            exceptions = try Self.compile(
                definition.exceptions,
                provider: name,
                field: "exceptions"
            )
            redirections = try Self.compile(
                definition.redirections,
                provider: name,
                field: "redirections"
            )
            forceRedirection = definition.forceRedirection
            patternLength = definition.urlPattern.count
        }

        private static func compile(
            _ patterns: [String],
            provider: String,
            field: String
        ) throws -> [NSRegularExpression] {
            try patterns.map { pattern in
                do {
                    return try NSRegularExpression(
                        pattern: pattern,
                        options: [.caseInsensitive]
                    )
                } catch {
                    throw ClearURLsRuleSetError.invalidPattern(
                        provider: provider,
                        field: field,
                        pattern: pattern
                    )
                }
            }
        }
    }

    private struct Source: Decodable {
        let providers: [String: Definition]
    }

    struct Definition: Decodable {
        let urlPattern: String
        let completeProvider: Bool
        let rules: [String]
        let referralMarketing: [String]
        let rawRules: [String]
        let exceptions: [String]
        let redirections: [String]
        let forceRedirection: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(
                keyedBy: ClearURLsRuleSetDefinitionCodingKeys.self
            )
            urlPattern = try container.decode(String.self, forKey: .urlPattern)
            completeProvider = try container.decodeIfPresent(
                Bool.self,
                forKey: .completeProvider
            ) ?? false
            rules = try container.decodeIfPresent([String].self, forKey: .rules) ?? []
            referralMarketing = try container.decodeIfPresent(
                [String].self,
                forKey: .referralMarketing
            ) ?? []
            rawRules = try container.decodeIfPresent([String].self, forKey: .rawRules) ?? []
            exceptions = try container.decodeIfPresent([String].self, forKey: .exceptions) ?? []
            redirections = try container.decodeIfPresent([String].self, forKey: .redirections) ?? []
            forceRedirection = try container.decodeIfPresent(
                Bool.self,
                forKey: .forceRedirection
            ) ?? false
        }

    }

    let providers: [Provider]
    let globalProvider: Provider?

    init(data: Data) throws {
        let source: Source
        do {
            source = try JSONDecoder().decode(Source.self, from: data)
        } catch {
            throw ClearURLsRuleSetError.invalidJSON
        }

        var providers: [Provider] = []
        var globalProvider: Provider?
        for name in source.providers.keys.sorted() {
            guard let definition = source.providers[name] else { continue }
            let provider = try Provider(name: name, definition: definition)
            if name == "globalRules" {
                globalProvider = provider
            } else {
                providers.append(provider)
            }
        }
        self.providers = providers
        self.globalProvider = globalProvider
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> Self {
        let url = bundle.url(forResource: "data.min", withExtension: "json")
            ?? bundle.url(forResource: "data.min", withExtension: "json", subdirectory: "Resources")
        guard let url else { throw ClearURLsRuleSetError.bundledResourceNotFound }
        do {
            return try Self(data: Data(contentsOf: url))
        } catch let error as ClearURLsRuleSetError {
            throw error
        } catch {
            throw ClearURLsRuleSetError.invalidJSON
        }
    }
}
