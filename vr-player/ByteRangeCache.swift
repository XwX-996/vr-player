import Foundation

nonisolated struct ByteRangeSegment: Codable, Equatable, Sendable {
    var lowerBound: Int64
    var upperBound: Int64

    var count: Int64 { max(upperBound - lowerBound, 0) }

    func contains(_ other: ByteRangeSegment) -> Bool {
        lowerBound <= other.lowerBound && upperBound >= other.upperBound
    }
}

nonisolated struct ByteRangeIndex: Codable, Equatable, Sendable {
    private(set) var segments: [ByteRangeSegment] = []

    mutating func insert(_ newSegment: ByteRangeSegment) {
        guard newSegment.upperBound > newSegment.lowerBound else { return }
        var merged = newSegment
        var result: [ByteRangeSegment] = []

        for segment in segments.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if segment.upperBound < merged.lowerBound {
                result.append(segment)
            } else if merged.upperBound < segment.lowerBound {
                result.append(merged)
                merged = segment
            } else {
                merged.lowerBound = min(merged.lowerBound, segment.lowerBound)
                merged.upperBound = max(merged.upperBound, segment.upperBound)
            }
        }
        result.append(merged)
        segments = result
    }

    func contains(_ segment: ByteRangeSegment) -> Bool {
        segments.contains(where: { $0.contains(segment) })
    }

    func isValid(contentLength: Int64, cacheFileSize: Int64) -> Bool {
        segments.allSatisfy { segment in
            segment.lowerBound >= 0
                && segment.upperBound <= contentLength
                && segment.upperBound <= cacheFileSize
                && segment.upperBound > segment.lowerBound
        }
    }
}

nonisolated enum ByteRangeCacheError: LocalizedError {
    case invalidOffset
    case invalidContentLength
    case sourceEndedEarly

    var errorDescription: String? {
        switch self {
        case .invalidOffset:
            "The video requested an invalid byte range."
        case .invalidContentLength:
            "The selected video does not report a valid file size."
        case .sourceEndedEarly:
            "The remote video stopped responding before the requested data arrived."
        }
    }
}

nonisolated final class ByteRangeCache: @unchecked Sendable {
    let contentLength: Int64
    let sourceModificationDate: Date?

    private let sourceHandle: FileHandle
    private let cacheHandle: FileHandle
    private let lock = NSLock()
    private var index: ByteRangeIndex

    init(
        sourceURL: URL,
        cacheKey: UUID,
        persistedIndexData: Data? = nil,
        persistedContentLength: Int64? = nil,
        persistedModificationDate: Date? = nil
    ) throws {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        contentLength = Int64(values.fileSize ?? 0)
        guard contentLength > 0 else { throw ByteRangeCacheError.invalidContentLength }
        sourceModificationDate = values.contentModificationDate
        sourceHandle = try FileHandle(forReadingFrom: sourceURL)

        let cacheURL = try Self.cacheFileURL(for: cacheKey)
        let cacheExisted = FileManager.default.fileExists(atPath: cacheURL.path)
        if !cacheExisted {
            FileManager.default.createFile(atPath: cacheURL.path, contents: nil)
        }
        cacheHandle = try FileHandle(forUpdating: cacheURL)
        let cacheFileSize = Int64(try cacheHandle.seekToEnd())

        let sameVersion = cacheExisted
            && persistedContentLength == contentLength
            && persistedModificationDate != nil
            && persistedModificationDate == sourceModificationDate
        if sameVersion,
           let persistedIndexData,
           let savedIndex = try? JSONDecoder().decode(ByteRangeIndex.self, from: persistedIndexData),
           savedIndex.isValid(contentLength: contentLength, cacheFileSize: cacheFileSize) {
            index = savedIndex
        } else {
            index = ByteRangeIndex()
            try cacheHandle.truncate(atOffset: 0)
        }
    }

    deinit {
        try? sourceHandle.close()
        try? cacheHandle.close()
    }

    func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length > 0 else { throw ByteRangeCacheError.invalidOffset }
        lock.lock()
        defer { lock.unlock() }

        let availableLength = Int(min(Int64(length), max(contentLength - offset, 0)))
        guard availableLength > 0 else { return Data() }
        let requested = ByteRangeSegment(
            lowerBound: offset,
            upperBound: offset + Int64(availableLength)
        )

        if index.contains(requested) {
            try cacheHandle.seek(toOffset: UInt64(offset))
            let cachedData = try cacheHandle.read(upToCount: availableLength) ?? Data()
            if cachedData.count == availableLength {
                return cachedData
            }
            index = ByteRangeIndex()
        }

        try sourceHandle.seek(toOffset: UInt64(offset))
        let data = try sourceHandle.read(upToCount: availableLength) ?? Data()
        guard !data.isEmpty else { throw ByteRangeCacheError.sourceEndedEarly }

        try cacheHandle.seek(toOffset: UInt64(offset))
        try cacheHandle.write(contentsOf: data)
        index.insert(
            ByteRangeSegment(
                lowerBound: offset,
                upperBound: offset + Int64(data.count)
            )
        )
        return data
    }

    func indexSnapshotData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? JSONEncoder().encode(index)
    }

    static func cacheFileURL(for cacheKey: UUID) throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "MediaRanges", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(cacheKey.uuidString).cache")
    }

    static func removeCachedData(for cacheKey: UUID) throws {
        let url = try cacheFileURL(for: cacheKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
