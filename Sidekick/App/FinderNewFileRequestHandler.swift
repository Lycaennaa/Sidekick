import AppKit

@MainActor
enum FinderNewFileRequestHandler {
    static func handle(_ requestURLs: [URL]) {
        for requestURL in requestURLs {
            guard let directoryURL = FinderNewFileRequestURL.directory(from: requestURL) else {
                continue
            }
            NewFileNamePrompt.run(in: directoryURL, fileStore: NewFileStore())
            return
        }
    }
}
