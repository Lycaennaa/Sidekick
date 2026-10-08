import Foundation
import XCTest

@MainActor
final class EquicordAsarArchiveTests: XCTestCase {
    func testBootstrapArchiveEscapesPayloadPathAndHasValidHeader() throws {
        let payloadURL = URL(fileURLWithPath: "/Users/example/Equicord payload.asar")
        let archive = try EquicordAsarArchive.makeBootstrap(payloadURL: payloadURL)
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("app.asar")
        try archive.write(to: archiveURL)

        let inspection = try EquicordAsarArchive.inspect(fileAt: archiveURL)
        XCTAssertEqual(inspection.fileCount, 2)
        XCTAssertTrue(archive.range(of: Data(EquicordAsarArchive.bootstrapMarker.utf8)) != nil)
        XCTAssertTrue(archive.range(of: Data("Equicord payload.asar".utf8)) != nil)
    }

    func testRejectsMalformedArchivesAndUnsafeMembers() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let malformedURL = root.appendingPathComponent("broken.asar")
        try Data("not an ASAR".utf8).write(to: malformedURL)

        XCTAssertThrowsError(try EquicordAsarArchive.inspect(fileAt: malformedURL))
        XCTAssertThrowsError(
            try EquicordAsarArchive.makeArchive(files: ["../outside.js": Data("bad".utf8)])
        )

        var outOfRangeArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("x".utf8)
        ])
        let offsetMarker = Data("\"offset\":\"0\"".utf8)
        guard let offsetRange = outOfRangeArchive.range(of: offsetMarker) else {
            XCTFail("Expected the archive writer to encode a zero-based file offset.")
            return
        }
        outOfRangeArchive.replaceSubrange(offsetRange, with: Data("\"offset\":\"9\"".utf8))
        let outOfRangeURL = root.appendingPathComponent("out-of-range.asar")
        try outOfRangeArchive.write(to: outOfRangeURL)

        XCTAssertThrowsError(try EquicordAsarArchive.inspect(fileAt: outOfRangeURL))
    }
}
