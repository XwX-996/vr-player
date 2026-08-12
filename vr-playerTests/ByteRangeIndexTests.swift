import XCTest
@testable import vr_player

final class ByteRangeIndexTests: XCTestCase {
    func testReadsAcrossBlocksAndReusesCachedBytes() throws {
        let fixture = try CacheTestFixture(blockSize: 4, perItemLimit: 12, globalLimit: 64)
        defer { fixture.cleanup() }
        let cacheKey = UUID()
        let original = Data(0..<12)
        let sourceURL = try fixture.makeSource(data: original)
        let sourceDate = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        do {
            let cache = try ByteRangeCache(sourceURL: sourceURL, cacheKey: cacheKey, store: fixture.store)
            XCTAssertEqual(try cache.read(offset: 2, length: 8), original.subdata(in: 2..<10))
        }
        XCTAssertTrue(fixture.store.containsCachedBlock(for: cacheKey, blockIndex: 0))
        XCTAssertTrue(fixture.store.containsCachedBlock(for: cacheKey, blockIndex: 1))
        XCTAssertTrue(fixture.store.containsCachedBlock(for: cacheKey, blockIndex: 2))

        try Data(repeating: 99, count: original.count).write(to: sourceURL)
        try FileManager.default.setAttributes(
            [.modificationDate: try XCTUnwrap(sourceDate)],
            ofItemAtPath: sourceURL.path
        )
        let restored = try ByteRangeCache(sourceURL: sourceURL, cacheKey: cacheKey, store: fixture.store)
        XCTAssertEqual(try restored.read(offset: 2, length: 8), original.subdata(in: 2..<10))
    }

    func testSourceChangeInvalidatesCachedBlocks() throws {
        let fixture = try CacheTestFixture(blockSize: 4, perItemLimit: 8, globalLimit: 64)
        defer { fixture.cleanup() }
        let cacheKey = UUID()
        let firstDate = Date(timeIntervalSince1970: 100)
        let changedDate = Date(timeIntervalSince1970: 200)

        try fixture.store.prepareAsset(
            for: cacheKey,
            contentLength: 4,
            sourceModificationDate: firstDate
        )
        XCTAssertTrue(fixture.store.storeBlock(Data([0, 1, 2, 3]), for: cacheKey, blockIndex: 0))
        XCTAssertTrue(fixture.store.containsCachedBlock(for: cacheKey, blockIndex: 0))

        try fixture.store.prepareAsset(
            for: cacheKey,
            contentLength: 4,
            sourceModificationDate: changedDate
        )
        XCTAssertFalse(fixture.store.containsCachedBlock(for: cacheKey, blockIndex: 0))
    }

    func testPerItemLimitEvictsLeastRecentlyUsedBlock() throws {
        let fixture = try CacheTestFixture(blockSize: 4, perItemLimit: 8, globalLimit: 64)
        defer { fixture.cleanup() }
        let cacheKey = UUID()
        try fixture.store.prepareAsset(for: cacheKey, contentLength: 12, sourceModificationDate: nil)

        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 0, count: 4), for: cacheKey, blockIndex: 0))
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 1, count: 4), for: cacheKey, blockIndex: 1))
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 2, count: 4), for: cacheKey, blockIndex: 2))

        XCTAssertFalse(fixture.store.containsCachedBlock(for: cacheKey, blockIndex: 0))
        XCTAssertTrue(fixture.store.containsCachedBlock(for: cacheKey, blockIndex: 1))
        XCTAssertTrue(fixture.store.containsCachedBlock(for: cacheKey, blockIndex: 2))
        XCTAssertEqual(try fixture.store.totalCachedBytes(), 8)
    }

    func testGlobalLRUEvictsInactiveItemAndProtectsCurrentItem() throws {
        let limit = TestCacheLimit(16)
        let fixture = try CacheTestFixture(
            blockSize: 4,
            perItemLimit: 8,
            limit: limit
        )
        defer { fixture.cleanup() }
        let currentKey = UUID()
        let otherKey = UUID()

        try fixture.store.prepareAsset(for: currentKey, contentLength: 8, sourceModificationDate: nil)
        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 0, count: 4), for: currentKey, blockIndex: 0))
        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 1, count: 4), for: currentKey, blockIndex: 1))
        try fixture.store.setLastAccessDate(.distantPast, for: currentKey)

        try fixture.store.prepareAsset(for: otherKey, contentLength: 8, sourceModificationDate: nil)
        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 2, count: 4), for: otherKey, blockIndex: 0))
        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 3, count: 4), for: otherKey, blockIndex: 1))

        fixture.store.beginAccess(for: currentKey)
        defer { fixture.store.endAccess(for: currentKey) }
        limit.value = 8
        try fixture.store.trimToGlobalLimit()

        XCTAssertTrue(fixture.store.containsCachedBlock(for: currentKey, blockIndex: 0))
        XCTAssertFalse(fixture.store.containsCachedBlock(for: otherKey, blockIndex: 0))
        XCTAssertEqual(try fixture.store.totalCachedBytes(), 8)
    }

    func testClearAllRemovesBlocksButStoreRemainsUsable() throws {
        let fixture = try CacheTestFixture(blockSize: 4, perItemLimit: 8, globalLimit: 64)
        defer { fixture.cleanup() }
        let firstKey = UUID()
        try fixture.store.prepareAsset(for: firstKey, contentLength: 4, sourceModificationDate: nil)
        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 1, count: 4), for: firstKey, blockIndex: 0))

        try fixture.store.removeAllCachedData()
        XCTAssertEqual(try fixture.store.totalCachedBytes(), 0)

        let secondKey = UUID()
        try fixture.store.prepareAsset(for: secondKey, contentLength: 4, sourceModificationDate: nil)
        XCTAssertTrue(fixture.store.storeBlock(Data(repeating: 2, count: 4), for: secondKey, blockIndex: 0))
        XCTAssertEqual(try fixture.store.totalCachedBytes(), 4)
    }

    func testCacheWriteFailureFallsBackToSourceReading() throws {
        let fixture = try CacheTestFixture(blockSize: 4, perItemLimit: 8, globalLimit: 64)
        defer { fixture.cleanup() }
        let invalidRoot = fixture.baseDirectory.appending(path: "not-a-directory")
        try Data([0]).write(to: invalidRoot)
        let failingStore = MediaCacheStore(
            rootDirectory: invalidRoot,
            blockSize: 4,
            perItemLimitBytes: 8,
            globalLimitProvider: { 64 }
        )
        let sourceData = Data(0..<8)
        let sourceURL = try fixture.makeSource(data: sourceData)
        let cacheKey = UUID()

        let cache = try ByteRangeCache(sourceURL: sourceURL, cacheKey: cacheKey, store: failingStore)
        XCTAssertEqual(try cache.read(offset: 1, length: 6), sourceData.subdata(in: 1..<7))
        XCTAssertFalse(failingStore.containsCachedBlock(for: cacheKey, blockIndex: 0))
    }

    func testCacheLimitRangeAndStepNormalization() {
        XCTAssertEqual(CacheStorageSettings.normalizedMegabytes(128), 512)
        XCTAssertEqual(CacheStorageSettings.normalizedMegabytes(1_080), 1_024)
        XCTAssertEqual(CacheStorageSettings.normalizedMegabytes(1_100), 1_152)
        XCTAssertEqual(CacheStorageSettings.normalizedMegabytes(8_000), 5_120)
        XCTAssertEqual(CacheStorageSettings.bytes(forMegabytes: 1_024), 1_073_741_824)
    }

    func testRequestCancellationRegistryIgnoresLateCancellation() {
        let registry = ResourceLoadingRequestRegistry()
        let request = NSObject()
        let requestID = ObjectIdentifier(request)

        registry.register(requestID)
        registry.cancel(requestID)
        XCTAssertTrue(registry.isCancelled(requestID))
        registry.finish(requestID)
        XCTAssertFalse(registry.isCancelled(requestID))
        registry.cancel(requestID)
        XCTAssertFalse(registry.isCancelled(requestID))
    }
}

private final class TestCacheLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int64

    init(_ value: Int64) {
        storedValue = value
    }

    var value: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private struct CacheTestFixture {
    let baseDirectory: URL
    let store: MediaCacheStore

    init(blockSize: Int, perItemLimit: Int64, globalLimit: Int64) throws {
        try self.init(
            blockSize: blockSize,
            perItemLimit: perItemLimit,
            limit: TestCacheLimit(globalLimit)
        )
    }

    init(blockSize: Int, perItemLimit: Int64, limit: TestCacheLimit) throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cacheRoot = baseDirectory.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        store = MediaCacheStore(
            rootDirectory: cacheRoot,
            blockSize: blockSize,
            perItemLimitBytes: perItemLimit,
            globalLimitProvider: { limit.value }
        )
    }

    func makeSource(data: Data) throws -> URL {
        let url = baseDirectory.appending(path: UUID().uuidString).appendingPathExtension("mp4")
        try data.write(to: url)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }
}
