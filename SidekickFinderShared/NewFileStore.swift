import Darwin
import Foundation

enum NewFileError: LocalizedError, Equatable {
    case invalidDirectory
    case invalidName
    case nameAlreadyExists(String)
    case coordinationFailed
    case posix(Int32)
    case finalizationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "The destination is not an accessible folder."
        case .invalidName:
            "Enter a valid filename without a path separator."
        case let .nameAlreadyExists(name):
            "An item named ‘\(name)’ already exists. Choose another name."
        case .coordinationFailed:
            "macOS could not coordinate this file operation."
        case let .posix(code):
            String(cString: strerror(code))
        case let .finalizationFailed(code):
            "The filesystem could not finalize the new file. It may still exist. \(String(cString: strerror(code)))"
        }
    }
}

struct NewFileStore {
    func createEmptyFile(in directory: URL, named name: String) throws -> URL {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw NewFileError.invalidDirectory
        }
        guard Self.isValidFilename(name) else {
            throw NewFileError.invalidName
        }

        let destinationURL = directory.standardizedFileURL
            .appendingPathComponent(name, isDirectory: false)
            .standardizedFileURL
        var coordinationError: NSError?
        var operationResult: Result<URL, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: destinationURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                guard coordinatedURL.standardizedFileURL == destinationURL else {
                    throw NewFileError.coordinationFailed
                }

                let descriptor = coordinatedURL.path.withCString {
                    Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(0o666))
                }
                guard descriptor >= 0 else {
                    let code = errno
                    if code == EEXIST {
                        throw NewFileError.nameAlreadyExists(name)
                    }
                    throw NewFileError.posix(code)
                }
                let closeResult = Darwin.close(descriptor)
                guard closeResult == 0 else {
                    throw NewFileError.finalizationFailed(errno)
                }
                return coordinatedURL
            }
        }
        if let coordinationError { throw coordinationError }
        guard let operationResult else {
            throw NewFileError.coordinationFailed
        }
        return try operationResult.get()
    }

    static func isValidFilename(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }
}
