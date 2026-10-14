import Foundation

enum FinderNewFileRequestURL {
    static let scheme = "sidekick-new-file"

    static func make(for directoryURL: URL) -> URL? {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "create"
        components.queryItems = [
            URLQueryItem(name: "directory", value: directoryURL.standardizedFileURL.path)
        ]
        return components.url
    }

    static func directory(from requestURL: URL) -> URL? {
        guard !requestURL.isFileURL,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == "create",
              components.path.isEmpty,
              components.fragment == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "directory",
              let path = queryItems[0].value,
              path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
