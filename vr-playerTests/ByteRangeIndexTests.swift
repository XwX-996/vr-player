import XCTest
@testable import vr_player

final class ByteRangeIndexTests: XCTestCase {
    func testMergesOverlappingAndAdjacentSegments() {
        var index = ByteRangeIndex()
        index.insert(ByteRangeSegment(lowerBound: 100, upperBound: 200))
        index.insert(ByteRangeSegment(lowerBound: 0, upperBound: 50))
        index.insert(ByteRangeSegment(lowerBound: 50, upperBound: 120))

        XCTAssertEqual(index.segments, [ByteRangeSegment(lowerBound: 0, upperBound: 200)])
        XCTAssertTrue(index.contains(ByteRangeSegment(lowerBound: 25, upperBound: 175)))
        XCTAssertFalse(index.contains(ByteRangeSegment(lowerBound: 25, upperBound: 201)))
    }

    func testKeepsDisjointSegmentsSorted() {
        var index = ByteRangeIndex()
        index.insert(ByteRangeSegment(lowerBound: 300, upperBound: 400))
        index.insert(ByteRangeSegment(lowerBound: 0, upperBound: 100))

        XCTAssertEqual(
            index.segments,
            [
                ByteRangeSegment(lowerBound: 0, upperBound: 100),
                ByteRangeSegment(lowerBound: 300, upperBound: 400),
            ]
        )
    }

    func testReloadFallsBackToSourceWhenCacheFileWasRemoved() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("mp4")
        let sourceData = Data((0..<128).map { UInt8($0) })
        try sourceData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let cacheKey = UUID()
        var persistedIndex: Data?
        var persistedLength: Int64?
        var persistedDate: Date?
        do {
            let cache = try ByteRangeCache(sourceURL: sourceURL, cacheKey: cacheKey)
            XCTAssertEqual(try cache.read(offset: 0, length: sourceData.count), sourceData)
            persistedIndex = cache.indexSnapshotData()
            persistedLength = cache.contentLength
            persistedDate = cache.sourceModificationDate
        }

        let cacheURL = try ByteRangeCache.cacheFileURL(for: cacheKey)
        try FileManager.default.removeItem(at: cacheURL)
        defer { try? ByteRangeCache.removeCachedData(for: cacheKey) }

        let restored = try ByteRangeCache(
            sourceURL: sourceURL,
            cacheKey: cacheKey,
            persistedIndexData: persistedIndex,
            persistedContentLength: persistedLength,
            persistedModificationDate: persistedDate
        )
        XCTAssertEqual(try restored.read(offset: 0, length: sourceData.count), sourceData)
    }

    func testRemovesCacheFileForDeletedPlaylistItem() throws {
        let cacheKey = UUID()
        let cacheURL = try ByteRangeCache.cacheFileURL(for: cacheKey)
        FileManager.default.createFile(atPath: cacheURL.path, contents: Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        try ByteRangeCache.removeCachedData(for: cacheKey)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testRequestCancellationRegistryIgnoresLateCancellation() {
        let registry = ResourceLoadingRequestRegistry()
        let firstRequest = NSObject()
        let firstID = ObjectIdentifier(firstRequest)

        registry.register(firstID)
        registry.cancel(firstID)
        XCTAssertTrue(registry.isCancelled(firstID))
        registry.finish(firstID)
        XCTAssertFalse(registry.isCancelled(firstID))

        registry.cancel(firstID)
        XCTAssertFalse(registry.isCancelled(firstID))
    }
}
