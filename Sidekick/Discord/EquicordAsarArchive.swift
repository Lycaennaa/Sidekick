import Foundation

nonisolated struct EquicordAsarInspection: Sendable {
    let byteCount: Int64
    let fileCount: Int
}

nonisolated enum EquicordAsarArchiveError: LocalizedError, Sendable {
    case invalidHeader
    case invalidMembers
    case acceptedSizeExceeded

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            "The downloaded Equicord archive has an invalid ASAR header."
        case .invalidMembers:
            "The downloaded Equicord archive has no application files."
        case .acceptedSizeExceeded:
            "The Equicord archive exceeds the installer's accepted size limit."
        }
    }
}

enum EquicordAsarArchive {
    nonisolated static let bootstrapMarker = "Sidekick Equicord bootstrap v1"
    nonisolated private static let maximumHeaderBytes = 8 * 1024 * 1024

    nonisolated private struct Entry: Encodable, Sendable {
        let size: Int
        let offset: String
    }

    nonisolated private struct Header: Encodable, Sendable {
        let files: [String: Entry]
    }

    nonisolated static func makeBootstrap(payloadURL: URL) throws -> Data {
        let pathData = try JSONEncoder().encode(payloadURL.path)
        guard let escapedPath = String(bytes: pathData, encoding: .utf8) else {
            throw EquicordAsarArchiveError.invalidHeader
        }
        let script = "// \(bootstrapMarker)\nrequire(\(escapedPath));\n"
        let package = try JSONSerialization.data(
            withJSONObject: ["name": "sidekick-discord-bootstrap", "main": "bootstrap.js", "version": "1.0.0"],
            options: [.sortedKeys]
        )
        return try makeArchive(files: [
            "bootstrap.js": Data(script.utf8),
            "package.json": package
        ])
    }

    nonisolated static func makeArchive(files: [String: Data]) throws -> Data {
        guard !files.isEmpty,
              files.keys.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }) else {
            throw EquicordAsarArchiveError.invalidMembers
        }

        var entries: [String: Entry] = [:]
        var content = Data()
        for name in files.keys.sorted() {
            guard let bytes = files[name] else { continue }
            entries[name] = Entry(size: bytes.count, offset: String(content.count))
            content.append(bytes)
        }

        let header = try JSONEncoder().encode(Header(files: entries))
        guard header.count <= maximumHeaderBytes else { throw EquicordAsarArchiveError.invalidHeader }
        let paddedHeaderCount = (header.count + 3) & ~3
        guard paddedHeaderCount <= Int(Int32.max) - 8 else { throw EquicordAsarArchiveError.invalidHeader }

        var archive = Data()
        appendWord(4, to: &archive)
        appendWord(UInt32(paddedHeaderCount + 8), to: &archive)
        appendWord(UInt32(paddedHeaderCount + 4), to: &archive)
        appendWord(UInt32(header.count), to: &archive)
        archive.append(header)
        archive.append(contentsOf: repeatElement(0, count: paddedHeaderCount - header.count))
        archive.append(content)
        return archive
    }

    nonisolated static func inspect(
        fileAt url: URL,
        maximumAcceptedBytes: Int64? = nil
    ) throws -> EquicordAsarInspection {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
              byteCount >= 16 else {
            throw EquicordAsarArchiveError.invalidHeader
        }
        if let maximumAcceptedBytes, byteCount > maximumAcceptedBytes {
            throw EquicordAsarArchiveError.acceptedSizeExceeded
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 16) ?? Data()
        guard prefix.count == 16,
              readWord(prefix, at: 0) == 4 else {
            throw EquicordAsarArchiveError.invalidHeader
        }

        let headerSize = Int(readWord(prefix, at: 4))
        let objectSize = Int(readWord(prefix, at: 8))
        let jsonSize = Int(readWord(prefix, at: 12))
        guard jsonSize > 0,
              jsonSize <= maximumHeaderBytes,
              jsonSize <= Int.max - 3 else {
            throw EquicordAsarArchiveError.invalidHeader
        }
        let paddedHeaderCount = (jsonSize + 3) & ~3
        guard headerSize == paddedHeaderCount + 8,
              objectSize == paddedHeaderCount + 4,
              byteCount >= Int64(16 + paddedHeaderCount) else {
            throw EquicordAsarArchiveError.invalidHeader
        }

        let headerData = try handle.read(upToCount: jsonSize) ?? Data()
        guard headerData.count == jsonSize,
              let root = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let files = root["files"] as? [String: Any],
              !files.isEmpty else {
            throw EquicordAsarArchiveError.invalidMembers
        }
        let dataStart = Int64(16 + paddedHeaderCount)
        let fileCount = try validateArchiveFiles(files, dataAreaLength: byteCount - dataStart)
        return EquicordAsarInspection(byteCount: byteCount, fileCount: fileCount)
    }

    nonisolated private static func validateArchiveFiles(
        _ rootFiles: [String: Any],
        dataAreaLength: Int64
    ) throws -> Int {
        var directories = [rootFiles]
        var fileCount = 0
        while let directory = directories.popLast() {
            for (name, value) in directory {
                if let children = try validatedArchiveEntry(
                    name: name,
                    value: value,
                    dataAreaLength: dataAreaLength
                ) {
                    directories.append(children)
                } else {
                    fileCount += 1
                }
            }
        }
        guard fileCount > 0 else { throw EquicordAsarArchiveError.invalidMembers }
        return fileCount
    }

    nonisolated private static func validatedArchiveEntry(
        name: String,
        value: Any,
        dataAreaLength: Int64
    ) throws -> [String: Any]? {
        guard isSafeArchiveName(name), let entry = value as? [String: Any] else {
            throw EquicordAsarArchiveError.invalidMembers
        }
        if let children = entry["files"] as? [String: Any] { return children }
        try validateArchiveLeaf(entry, dataAreaLength: dataAreaLength)
        return nil
    }

    nonisolated private static func isSafeArchiveName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    nonisolated private static func validateArchiveLeaf(
        _ entry: [String: Any],
        dataAreaLength: Int64
    ) throws {
        if let link = entry["link"] as? String {
            guard !link.isEmpty else { throw EquicordAsarArchiveError.invalidMembers }
            return
        }
        guard let rawSize = entry["size"] as? NSNumber,
              rawSize.doubleValue >= 0,
              rawSize.doubleValue == Double(rawSize.int64Value) else {
            throw EquicordAsarArchiveError.invalidMembers
        }
        if entry["unpacked"] as? Bool == true { return }
        guard let offsetString = entry["offset"] as? String,
              !offsetString.isEmpty,
              offsetString.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let offset = Int64(offsetString) else {
            throw EquicordAsarArchiveError.invalidMembers
        }
        let (end, overflow) = offset.addingReportingOverflow(rawSize.int64Value)
        guard !overflow, end <= dataAreaLength else {
            throw EquicordAsarArchiveError.invalidHeader
        }
    }

    nonisolated static func containsBootstrapMarker(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= 64 * 1024,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 64 * 1024) else { return false }
        return bytes.range(of: Data(bootstrapMarker.utf8)) != nil
    }

    nonisolated private static func appendWord(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    nonisolated private static func readWord(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
