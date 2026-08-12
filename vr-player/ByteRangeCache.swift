import Foundation

nonisolated enum CacheStorageSettings {
    static let limitMegabytesKey = "mediaCacheLimitMegabytes"
    static let minimumMegabytes = 512.0
    static let maximumMegabytes = 5_120.0
    static let stepMegabytes = 128.0
    static let defaultMegabytes = 1_024.0

    static func normalizedMegabytes(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMegabytes }
        let clamped = min(max(value, minimumMegabytes), maximumMegabytes)
        return (clamped / stepMegabytes).rounded() * stepMegabytes
    }

    static func bytes(forMegabytes value: Double) -> Int64 {
        Int64(normalizedMegabytes(value) * 1_048_576)
    }

    static var configuredLimitBytes: Int64 {
        let stored = UserDefaults.standard.double(forKey: limitMegabytesKey)
        let megabytes = stored == 0 ? defaultMegabytes : stored
        return bytes(forMegabytes: megabytes)
    }
}

nonisolated enum ByteRangeCacheError: LocalizedError {
    case invalidOffset
    case invalidContentLength
    case sourceEndedEarly

    var errorDescription: String? {
        switch self {
        case .invalidOffset:
            "视频请求了无效的字节范围。"
        case .invalidContentLength:
            "所选视频未提供有效的文件大小。"
        case .sourceEndedEarly:
            "远程视频在读取完成前停止响应。"
        }
    }
}

nonisolated struct MediaCacheMetadata: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let contentLength: Int64
    let sourceModificationDate: Date?
    var lastAccessDate: Date
    var cachedBytes: Int64
}

nonisolated final class MediaCacheStore: @unchecked Sendable {
    static let blockSize = 1_048_576
    static let perItemLimitBytes: Int64 = 256 * 1_048_576
    static let shared = MediaCacheStore(
        rootDirectory: defaultRootDirectory(),
        globalLimitProvider: { CacheStorageSettings.configuredLimitBytes }
    )

    let rootDirectory: URL?
    let blockSize: Int
    let perItemLimitBytes: Int64

    private let globalLimitProvider: @Sendable () -> Int64
    private let fileManager: FileManager
    private let lock = NSLock()
    private var activeAccessCounts: [UUID: Int] = [:]
    private var lastMetadataTouches: [UUID: Date] = [:]

    init(
        rootDirectory: URL?,
        blockSize: Int = MediaCacheStore.blockSize,
        perItemLimitBytes: Int64 = MediaCacheStore.perItemLimitBytes,
        fileManager: FileManager = .default,
        globalLimitProvider: @escaping @Sendable () -> Int64
    ) {
        self.rootDirectory = rootDirectory
        self.blockSize = max(blockSize, 1)
        self.perItemLimitBytes = max(perItemLimitBytes, 0)
        self.fileManager = fileManager
        self.globalLimitProvider = globalLimitProvider
    }

    func beginAccess(for cacheKey: UUID) {
        lock.withLock {
            activeAccessCounts[cacheKey, default: 0] += 1
        }
    }

    func endAccess(for cacheKey: UUID) {
        lock.withLock {
            let now = Date.now
            try? updateMetadataLocked(for: cacheKey, lastAccessDate: now)
            lastMetadataTouches[cacheKey] = now
            let remainingAccessCount = max((activeAccessCounts[cacheKey] ?? 1) - 1, 0)
            if remainingAccessCount == 0 {
                activeAccessCounts.removeValue(forKey: cacheKey)
            } else {
                activeAccessCounts[cacheKey] = remainingAccessCount
            }
            try? trimToGlobalLimitLocked()
        }
    }

    func prepareAsset(
        for cacheKey: UUID,
        contentLength: Int64,
        sourceModificationDate: Date?
    ) throws {
        try lock.withLock {
            guard let rootDirectory else { return }
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let itemDirectory = itemDirectoryURL(for: cacheKey, rootDirectory: rootDirectory)
            let metadataURL = itemDirectory.appending(path: "metadata.json")
            let existingMetadata = try? readMetadata(at: metadataURL)
            let isCurrent = existingMetadata?.version == MediaCacheMetadata.currentVersion
                && existingMetadata?.contentLength == contentLength
                && existingMetadata?.sourceModificationDate == sourceModificationDate

            if !isCurrent, fileManager.fileExists(atPath: itemDirectory.path) {
                try fileManager.removeItem(at: itemDirectory)
            }
            try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
            let cachedBytes = isCurrent
                ? try blockFiles(in: itemDirectory).reduce(Int64.zero) { $0 + $1.size }
                : 0
            let now = Date.now
            try writeMetadata(
                MediaCacheMetadata(
                    version: MediaCacheMetadata.currentVersion,
                    contentLength: contentLength,
                    sourceModificationDate: sourceModificationDate,
                    lastAccessDate: now,
                    cachedBytes: cachedBytes
                ),
                to: metadataURL
            )
            lastMetadataTouches[cacheKey] = now
            try trimToGlobalLimitLocked()
        }
    }

    func readBlock(
        for cacheKey: UUID,
        blockIndex: Int64,
        expectedLength: Int
    ) -> Data? {
        lock.withLock {
            guard expectedLength > 0,
                  let rootDirectory,
                  let blockURL = blockURL(
                    for: cacheKey,
                    blockIndex: blockIndex,
                    rootDirectory: rootDirectory
                  ),
                  let data = try? Data(contentsOf: blockURL),
                  data.count == expectedLength
            else {
                return nil
            }

            let now = Date.now
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: blockURL.path)
            if now.timeIntervalSince(lastMetadataTouches[cacheKey] ?? .distantPast) >= 5,
               (try? updateMetadataLocked(for: cacheKey, lastAccessDate: now)) != nil {
                lastMetadataTouches[cacheKey] = now
            }
            return data
        }
    }

    func storeBlock(_ data: Data, for cacheKey: UUID, blockIndex: Int64) -> Bool {
        lock.withLock {
            guard !data.isEmpty,
                  data.count <= blockSize,
                  let rootDirectory,
                  let blockURL = blockURL(
                    for: cacheKey,
                    blockIndex: blockIndex,
                    rootDirectory: rootDirectory
                  )
            else {
                return false
            }

            do {
                let itemDirectory = itemDirectoryURL(for: cacheKey, rootDirectory: rootDirectory)
                try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
                let previousSize = try? blockURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                try data.write(to: blockURL, options: .atomic)
                let now = Date.now
                try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: blockURL.path)
                let metadata = try metadataLocked(for: cacheKey)
                var cachedBytes = metadata.cachedBytes + Int64(data.count - (previousSize ?? 0))
                if cachedBytes > perItemLimitBytes {
                    cachedBytes -= try trimItemLocked(
                        cacheKey: cacheKey,
                        preservingBlockIndex: blockIndex,
                        currentCachedBytes: cachedBytes
                    )
                }
                try updateMetadataLocked(
                    for: cacheKey,
                    lastAccessDate: now,
                    cachedBytes: cachedBytes
                )
                lastMetadataTouches[cacheKey] = now
                try trimToGlobalLimitLocked()
                return true
            } catch {
                try? fileManager.removeItem(at: blockURL)
                try? reconcileCachedBytesLocked(for: cacheKey)
                return false
            }
        }
    }

    func totalCachedBytes() throws -> Int64 {
        try lock.withLock {
            try totalCachedBytesLocked()
        }
    }

    func removeCachedData(for cacheKey: UUID) throws {
        try lock.withLock {
            guard let rootDirectory else { return }
            let directory = itemDirectoryURL(for: cacheKey, rootDirectory: rootDirectory)
            guard fileManager.fileExists(atPath: directory.path) else { return }
            try fileManager.removeItem(at: directory)
            lastMetadataTouches.removeValue(forKey: cacheKey)
        }
    }

    func removeAllCachedData() throws {
        try lock.withLock {
            guard let rootDirectory else { return }
            if fileManager.fileExists(atPath: rootDirectory.path) {
                try fileManager.removeItem(at: rootDirectory)
            }
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            lastMetadataTouches.removeAll()
        }
    }

    func trimToGlobalLimit() throws {
        try lock.withLock {
            try reconcileAllCachedBytesLocked()
            try trimToGlobalLimitLocked()
        }
    }

    func containsCachedBlock(for cacheKey: UUID, blockIndex: Int64) -> Bool {
        lock.withLock {
            guard let rootDirectory,
                  let url = blockURL(for: cacheKey, blockIndex: blockIndex, rootDirectory: rootDirectory)
            else { return false }
            return fileManager.fileExists(atPath: url.path)
        }
    }

    func setLastAccessDate(_ date: Date, for cacheKey: UUID) throws {
        try lock.withLock {
            try updateMetadataLocked(for: cacheKey, lastAccessDate: date)
            lastMetadataTouches[cacheKey] = date
        }
    }

    private static func defaultRootDirectory() -> URL? {
        try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "MediaRanges", directoryHint: .isDirectory)
    }

    private func itemDirectoryURL(for cacheKey: UUID, rootDirectory: URL) -> URL {
        rootDirectory.appending(path: cacheKey.uuidString, directoryHint: .isDirectory)
    }

    private func blockURL(for cacheKey: UUID, blockIndex: Int64, rootDirectory: URL) -> URL? {
        guard blockIndex >= 0 else { return nil }
        return itemDirectoryURL(for: cacheKey, rootDirectory: rootDirectory)
            .appending(path: String(format: "%020lld.block", blockIndex))
    }

    private func readMetadata(at url: URL) throws -> MediaCacheMetadata {
        try JSONDecoder().decode(MediaCacheMetadata.self, from: Data(contentsOf: url))
    }

    private func writeMetadata(_ metadata: MediaCacheMetadata, to url: URL) throws {
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
    }

    private func metadataLocked(for cacheKey: UUID) throws -> MediaCacheMetadata {
        guard let rootDirectory else { throw CocoaError(.fileNoSuchFile) }
        let metadataURL = itemDirectoryURL(for: cacheKey, rootDirectory: rootDirectory)
            .appending(path: "metadata.json")
        return try readMetadata(at: metadataURL)
    }

    private func updateMetadataLocked(
        for cacheKey: UUID,
        lastAccessDate: Date,
        cachedBytes: Int64? = nil
    ) throws {
        guard let rootDirectory else { return }
        let metadataURL = itemDirectoryURL(for: cacheKey, rootDirectory: rootDirectory)
            .appending(path: "metadata.json")
        var metadata = try readMetadata(at: metadataURL)
        metadata.lastAccessDate = lastAccessDate
        if let cachedBytes {
            metadata.cachedBytes = max(cachedBytes, 0)
        }
        try writeMetadata(metadata, to: metadataURL)
    }

    private func reconcileCachedBytesLocked(for cacheKey: UUID) throws {
        guard let rootDirectory else { return }
        let directory = itemDirectoryURL(for: cacheKey, rootDirectory: rootDirectory)
        let actualBytes = try blockFiles(in: directory).reduce(Int64.zero) { $0 + $1.size }
        try updateMetadataLocked(
            for: cacheKey,
            lastAccessDate: .now,
            cachedBytes: actualBytes
        )
    }

    private func reconcileAllCachedBytesLocked() throws {
        guard let rootDirectory,
              fileManager.fileExists(atPath: rootDirectory.path)
        else { return }
        let directories = try cacheDirectoriesLocked(rootDirectory: rootDirectory)
        for directory in directories {
            let actualBytes = try blockFiles(in: directory.url).reduce(Int64.zero) { $0 + $1.size }
            guard actualBytes != directory.size,
                  let metadata = try? metadataLocked(for: directory.cacheKey)
            else { continue }
            try updateMetadataLocked(
                for: directory.cacheKey,
                lastAccessDate: metadata.lastAccessDate,
                cachedBytes: actualBytes
            )
        }
    }

    private func trimItemLocked(
        cacheKey: UUID,
        preservingBlockIndex: Int64,
        currentCachedBytes: Int64
    ) throws -> Int64 {
        guard let rootDirectory else { return 0 }
        let directory = itemDirectoryURL(for: cacheKey, rootDirectory: rootDirectory)
        let blocks = try blockFiles(in: directory)
        var total = currentCachedBytes
        var removedBytes: Int64 = 0

        for block in blocks.sorted(by: { $0.lastAccessDate < $1.lastAccessDate })
        where total > perItemLimitBytes && block.index != preservingBlockIndex {
            try fileManager.removeItem(at: block.url)
            total -= block.size
            removedBytes += block.size
        }
        return removedBytes
    }

    private func trimToGlobalLimitLocked() throws {
        guard let rootDirectory,
              fileManager.fileExists(atPath: rootDirectory.path)
        else { return }

        let limit = max(globalLimitProvider(), 0)
        let directories = try cacheDirectoriesLocked(rootDirectory: rootDirectory)
        var total = directories.reduce(Int64.zero) { $0 + $1.size }
        for directory in directories.sorted(by: { $0.lastAccessDate < $1.lastAccessDate })
        where total > limit && activeAccessCounts[directory.cacheKey] == nil {
            try fileManager.removeItem(at: directory.url)
            total -= directory.size
        }
    }

    private func totalCachedBytesLocked() throws -> Int64 {
        guard let rootDirectory,
              fileManager.fileExists(atPath: rootDirectory.path)
        else { return 0 }
        return try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).reduce(Int64.zero) { total, url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return total }
            return total + (try blockFiles(in: url).reduce(Int64.zero) { $0 + $1.size })
        }
    }

    private func cacheDirectoriesLocked(rootDirectory: URL) throws -> [CacheDirectoryInfo] {
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let cacheKey = UUID(uuidString: url.lastPathComponent)
            else { return nil }
            let metadataURL = url.appending(path: "metadata.json")
            let metadata = try? readMetadata(at: metadataURL)
            let size: Int64
            if let metadata {
                size = metadata.cachedBytes
            } else {
                size = try blockFiles(in: url).reduce(Int64.zero) { $0 + $1.size }
            }
            return CacheDirectoryInfo(
                cacheKey: cacheKey,
                url: url,
                size: size,
                lastAccessDate: metadata?.lastAccessDate ?? .distantPast
            )
        }
    }

    private func blockFiles(in directory: URL) throws -> [BlockFileInfo] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            guard url.pathExtension == "block",
                  let index = Int64(url.deletingPathExtension().lastPathComponent)
            else { return nil }
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true else { return nil }
            return BlockFileInfo(
                index: index,
                url: url,
                size: Int64(values.fileSize ?? 0),
                lastAccessDate: values.contentModificationDate ?? .distantPast
            )
        }
    }
}

nonisolated private struct BlockFileInfo: Sendable {
    let index: Int64
    let url: URL
    let size: Int64
    let lastAccessDate: Date
}

nonisolated private struct CacheDirectoryInfo: Sendable {
    let cacheKey: UUID
    let url: URL
    let size: Int64
    let lastAccessDate: Date
}

nonisolated final class ByteRangeCache: @unchecked Sendable {
    let contentLength: Int64
    let sourceModificationDate: Date?

    private let cacheKey: UUID
    private let sourceHandle: FileHandle
    private let store: MediaCacheStore
    private let lock = NSLock()
    private var isCachingEnabled: Bool

    init(
        sourceURL: URL,
        cacheKey: UUID,
        store: MediaCacheStore = .shared
    ) throws {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        contentLength = Int64(values.fileSize ?? 0)
        guard contentLength > 0 else { throw ByteRangeCacheError.invalidContentLength }
        sourceModificationDate = values.contentModificationDate
        self.cacheKey = cacheKey
        self.store = store
        sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        store.beginAccess(for: cacheKey)
        do {
            try store.prepareAsset(
                for: cacheKey,
                contentLength: contentLength,
                sourceModificationDate: sourceModificationDate
            )
            isCachingEnabled = true
        } catch {
            isCachingEnabled = false
        }
    }

    deinit {
        try? sourceHandle.close()
        store.endAccess(for: cacheKey)
    }

    func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length > 0 else { throw ByteRangeCacheError.invalidOffset }
        return try lock.withLock {
            let availableLength = Int(min(Int64(length), max(contentLength - offset, 0)))
            guard availableLength > 0 else { return Data() }

            var result = Data()
            result.reserveCapacity(availableLength)
            var currentOffset = offset
            let requestedEnd = offset + Int64(availableLength)

            while currentOffset < requestedEnd {
                let blockIndex = currentOffset / Int64(store.blockSize)
                let blockStart = blockIndex * Int64(store.blockSize)
                let expectedBlockLength = Int(min(Int64(store.blockSize), contentLength - blockStart))
                let block: Data
                if isCachingEnabled, let cachedBlock = store.readBlock(
                    for: cacheKey,
                    blockIndex: blockIndex,
                    expectedLength: expectedBlockLength
                ) {
                    block = cachedBlock
                } else {
                    block = try readAndCacheBlock(
                        blockIndex: blockIndex,
                        blockStart: blockStart,
                        length: expectedBlockLength
                    )
                }

                let lowerBound = Int(currentOffset - blockStart)
                let requestedFromBlock = Int(min(
                    Int64(block.count - lowerBound),
                    requestedEnd - currentOffset
                ))
                guard requestedFromBlock > 0 else { throw ByteRangeCacheError.sourceEndedEarly }
                result.append(block.subdata(in: lowerBound..<(lowerBound + requestedFromBlock)))
                currentOffset += Int64(requestedFromBlock)
            }
            return result
        }
    }

    private func readAndCacheBlock(blockIndex: Int64, blockStart: Int64, length: Int) throws -> Data {
        let data = try readSource(offset: blockStart, length: length)
        if isCachingEnabled,
           !store.storeBlock(data, for: cacheKey, blockIndex: blockIndex) {
            isCachingEnabled = false
        }
        return data
    }

    private func readSource(offset: Int64, length: Int) throws -> Data {
        try sourceHandle.seek(toOffset: UInt64(offset))
        var data = Data()
        data.reserveCapacity(length)
        while data.count < length {
            let chunk = try sourceHandle.read(upToCount: length - data.count) ?? Data()
            guard !chunk.isEmpty else { throw ByteRangeCacheError.sourceEndedEarly }
            data.append(chunk)
        }
        return data
    }
}

private extension NSLock {
    nonisolated func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
