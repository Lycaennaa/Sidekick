import AppKit
import FinderSync
import Foundation
final class FinderSyncExtension: FIFinderSync {

    private let observedDirectoriesLock = NSLock()
    private var observedDirectories = Set<URL>()

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Volumes", isDirectory: true),
            URL(fileURLWithPath: "/Network", isDirectory: true)
        ]
    }

    override func beginObservingDirectory(at url: URL) {
        observedDirectoriesLock.lock()
        observedDirectories.insert(url.standardizedFileURL)
        observedDirectoriesLock.unlock()
    }

    override func endObservingDirectory(at url: URL) {
        observedDirectoriesLock.lock()
        observedDirectories.remove(url.standardizedFileURL)
        observedDirectoriesLock.unlock()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        menu(
            for: menuKind,
            targetedURL: FIFinderSyncController.default().targetedURL()
        )
    }

    func menu(for menuKind: FIMenuKind, targetedURL: URL?) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer:
            break
        default:
            return nil
        }

        guard destinationDirectory(for: menuKind, targetedURL: targetedURL) != nil else {
            return nil
        }

        let item = NSMenuItem(title: "New File", action: #selector(createNewFile(_:)), keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }
    func destinationDirectory(for menuKind: FIMenuKind, targetedURL: URL?) -> URL? {
        switch menuKind {
        case .contextualMenuForItems:
            guard let targetedURL, Self.isDirectoryURL(targetedURL, rejectingPackages: true) else {
                return nil
            }
            return targetedURL
        case .contextualMenuForContainer:
            if let targetedURL, Self.isDirectoryURL(targetedURL, rejectingPackages: false) {
                return targetedURL
            }
            return singleObservedDirectory()
        default:
            return nil
        }
    }

    private func singleObservedDirectory() -> URL? {
        observedDirectoriesLock.lock()
        let count = observedDirectories.count
        let directory = observedDirectories.first
        observedDirectoriesLock.unlock()

        guard count == 1 else {
            return nil
        }
        return directory
    }

    private static func isDirectoryURL(_ url: URL, rejectingPackages: Bool) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard !rejectingPackages || values?.isPackage != true else { return false }
        return values?.isDirectory ?? url.hasDirectoryPath
    }

    @objc func createNewFile(_ sender: NSMenuItem) {
        let targetedURL = FIFinderSyncController.default().targetedURL()
        guard let directoryURL = destinationDirectory(
            for: .contextualMenuForContainer,
            targetedURL: targetedURL
        ) else {
            return
        }

        guard let requestURL = FinderNewFileRequestURL.make(for: directoryURL) else {
            return
        }
        Task { @MainActor in
            _ = NSWorkspace.shared.open(requestURL)
        }
    }
}
