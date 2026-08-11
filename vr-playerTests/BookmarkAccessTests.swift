import XCTest
@testable import vr_player

final class BookmarkAccessTests: XCTestCase {
    @MainActor
    func testBookmarkRoundTrip() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("mp4")
        try Data([0, 1, 2, 3]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let bookmark = try BookmarkAccess.createBookmark(for: fileURL)
        let resolved = try SecurityScopedFile(bookmarkData: bookmark)
        XCTAssertEqual(resolved.url.standardizedFileURL, fileURL.standardizedFileURL)
    }

    func testImportContainerValidationMatchesSupportedMedia() throws {
        XCTAssertNoThrow(try MediaImportValidator.validateContainer(url: URL(fileURLWithPath: "/tmp/sample.mp4")))
        XCTAssertNoThrow(try MediaImportValidator.validateContainer(url: URL(fileURLWithPath: "/tmp/sample.MOV")))
        XCTAssertThrowsError(try MediaImportValidator.validateContainer(url: URL(fileURLWithPath: "/tmp/sample.avi")))
        XCTAssertThrowsError(try MediaImportValidator.validateContainer(url: URL(fileURLWithPath: "/tmp/sample.webm")))
    }
}
