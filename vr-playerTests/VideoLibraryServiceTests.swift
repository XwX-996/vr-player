@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import SwiftData
import UIKit
import XCTest
@testable import vr_player

final class VideoLibraryServiceTests: XCTestCase {
    @MainActor
    func testPersistsThumbnailDataAndDeletesItWithVideo() throws {
        let fixture = try LibraryFixture()
        let thumbnailData = Data([0xff, 0xd8, 0xff, 0xd9])
        let video = fixture.makeItem(name: "Thumbnail", thumbnailData: thumbnailData)
        fixture.context.insert(video)
        try fixture.context.save()

        let storedItems = try fixture.context.fetch(FetchDescriptor<PlaylistItem>())
        XCTAssertEqual(storedItems.count, 1)
        XCTAssertEqual(storedItems.first?.thumbnailData, thumbnailData)

        try fixture.service().delete(folders: [], items: [video])

        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<PlaylistItem>()).isEmpty)
    }

    func testThumbnailGenerationFailureReturnsNil() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("mp4")

        let thumbnailData = await VideoThumbnailGenerator.generate(from: missingURL)

        XCTAssertNil(thumbnailData)
    }

    func testGeneratesBoundedJPEGThumbnail() async throws {
        let videoURL = try await makeTestVideo()
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let generatedData = await VideoThumbnailGenerator.generate(from: videoURL)
        let thumbnailData = try XCTUnwrap(generatedData)
        let thumbnail = try XCTUnwrap(UIImage(data: thumbnailData))

        XCTAssertEqual(thumbnailData.prefix(2), Data([0xff, 0xd8]))
        XCTAssertLessThanOrEqual(thumbnail.size.width * thumbnail.scale, 304)
        XCTAssertLessThanOrEqual(thumbnail.size.height * thumbnail.scale, 192)
    }

    func testThumbnailTimeUsesVideoMidpoint() {
        XCTAssertEqual(
            VideoThumbnailGenerator.thumbnailTime(for: CMTime(seconds: 10, preferredTimescale: 600)).seconds,
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            VideoThumbnailGenerator.thumbnailTime(for: CMTime(seconds: 1, preferredTimescale: 600)).seconds,
            0.5,
            accuracy: 0.001
        )
    }

    func testFolderScannerKeepsRootHierarchyAndFiltersUnsupportedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "旅行-\(UUID().uuidString)")
        let nested = root.appending(path: "日本/day1", directoryHint: .isDirectory)
        let empty = root.appending(path: "空目录", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: nested.appending(path: "a.MP4"))
        try Data().write(to: nested.appending(path: "b.mov"))
        try Data().write(to: nested.appending(path: "notes.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let candidates = try FolderImportScanner.scan(directoryURL: root)

        XCTAssertEqual(candidates.map(\.url.lastPathComponent), ["a.MP4", "b.mov"])
        XCTAssertEqual(candidates.first?.folderComponents, [root.lastPathComponent, "日本", "day1"])
        XCTAssertFalse(candidates.contains { $0.folderComponents.contains("空目录") })
    }

    private func makeTestVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("mp4")
        let width = 640
        let height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw ThumbnailTestError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ThumbnailTestError.cannotStartWriting }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0...2 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            let pixelBuffer = try makePixelBuffer(
                from: adaptor,
                width: width,
                height: height
            )
            let presentationTime = CMTime(
                seconds: Double(frameIndex) * 0.5,
                preferredTimescale: 600
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ThumbnailTestError.cannotAppendFrame
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ThumbnailTestError.cannotFinishWriting
        }
        return url
    }

    private func makePixelBuffer(
        from adaptor: AVAssetWriterInputPixelBufferAdaptor,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw ThumbnailTestError.missingPixelBufferPool
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else {
            throw ThumbnailTestError.cannotCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw ThumbnailTestError.cannotCreateContext
        }
        context.setFillColor(red: 0.1, green: 0.35, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.95, green: 0.2, blue: 0.15, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 3, height: height))
        return pixelBuffer
    }

    @MainActor
    func testCreatesNestedFoldersAndKeepsRootItemsUnassigned() throws {
        let fixture = try LibraryFixture()
        let service = fixture.service()
        let rootVideo = fixture.makeItem(name: "Root")

        let parent = try service.createFolder(named: "旅行", in: nil)
        let child = try service.createFolder(named: "日本", in: parent)
        fixture.context.insert(rootVideo)
        try fixture.context.save()

        XCTAssertNil(parent.parent)
        XCTAssertEqual(child.parent?.id, parent.id)
        XCTAssertNil(rootVideo.folder)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<VideoFolder>()).count, 2)
    }

    @MainActor
    func testRejectsEmptyAndCaseInsensitiveDuplicateFolderNames() throws {
        let fixture = try LibraryFixture()
        let service = fixture.service()
        _ = try service.createFolder(named: " Movies ", in: nil)

        XCTAssertThrowsError(try service.createFolder(named: "movies", in: nil)) { error in
            XCTAssertEqual(error as? VideoLibraryError, .duplicateFolderName("movies"))
        }
        XCTAssertThrowsError(try service.createFolder(named: "  ", in: nil)) { error in
            XCTAssertEqual(error as? VideoLibraryError, .emptyName)
        }
    }

    @MainActor
    func testMovesFoldersAndVideosButRejectsCycles() throws {
        let fixture = try LibraryFixture()
        let service = fixture.service()
        let parent = try service.createFolder(named: "Parent", in: nil)
        let child = try service.createFolder(named: "Child", in: parent)
        let destination = try service.createFolder(named: "Destination", in: nil)
        let video = fixture.makeItem(name: "Video", folder: parent)
        fixture.context.insert(video)
        try fixture.context.save()

        try service.move(folders: [], items: [video], to: destination)
        XCTAssertEqual(video.folder?.id, destination.id)

        XCTAssertThrowsError(try service.move(folders: [parent], items: [], to: child)) { error in
            XCTAssertEqual(error as? VideoLibraryError, .invalidMove)
        }
        XCTAssertNil(parent.parent)
        XCTAssertEqual(child.parent?.id, parent.id)
    }

    @MainActor
    func testMoveFailsAtomicallyWhenDestinationHasDuplicateFolderName() throws {
        let fixture = try LibraryFixture()
        let service = fixture.service()
        let source = try service.createFolder(named: "Source", in: nil)
        let destination = try service.createFolder(named: "Destination", in: nil)
        let moving = try service.createFolder(named: "Trips", in: source)
        _ = try service.createFolder(named: "trips", in: destination)

        XCTAssertThrowsError(try service.move(folders: [moving], items: [], to: destination)) { error in
            XCTAssertEqual(error as? VideoLibraryError, .duplicateFolderName("Trips"))
        }
        XCTAssertEqual(moving.parent?.id, source.id)
    }

    @MainActor
    func testRecursiveDeleteRemovesFoldersVideosAndCaches() throws {
        let fixture = try LibraryFixture()
        let cache = RecordingCacheStore()
        let service = fixture.service(cacheStore: cache)
        let parent = try service.createFolder(named: "Parent", in: nil)
        let child = try service.createFolder(named: "Child", in: parent)
        let parentVideo = fixture.makeItem(name: "Parent Video", folder: parent)
        let childVideo = fixture.makeItem(name: "Child Video", folder: child)
        fixture.context.insert(parentVideo)
        fixture.context.insert(childVideo)
        try fixture.context.save()

        try service.delete(folders: [parent], items: [])

        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<VideoFolder>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<PlaylistItem>()).isEmpty)
        XCTAssertEqual(cache.removedIDs, Set([parentVideo.id, childVideo.id]))
    }

    @MainActor
    func testCacheFailureKeepsFolderAndVideoRecords() throws {
        let fixture = try LibraryFixture()
        let cache = RecordingCacheStore(shouldFail: true)
        let service = fixture.service(cacheStore: cache)
        let folder = try service.createFolder(named: "Keep", in: nil)
        let video = fixture.makeItem(name: "Keep Video", folder: folder)
        fixture.context.insert(video)
        try fixture.context.save()

        XCTAssertThrowsError(try service.delete(folders: [folder], items: [])) { error in
            XCTAssertEqual(error as? VideoLibraryError, .cacheDeletionFailed(["Keep Video"]))
        }
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<VideoFolder>()).count, 1)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<PlaylistItem>()).count, 1)
    }


    @MainActor
    func testFolderImportCreatesHierarchyAndMergesCaseInsensitiveFolders() throws {
        let fixture = try LibraryFixture()
        let existingRoot = VideoFolder(name: "旅行")
        fixture.context.insert(existingRoot)
        try fixture.context.save()
        let service = FolderImportService(modelContext: fixture.context, cacheStore: RecordingCacheStore())

        let summary = try service.apply(
            [fixture.preparedVideo(identity: "one", folders: ["旅行", "日本"])],
            destination: nil
        )

        let folders = try fixture.context.fetch(FetchDescriptor<VideoFolder>())
        let items = try fixture.context.fetch(FetchDescriptor<PlaylistItem>())
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(folders.filter { $0.parent == nil }.map(\.id), [existingRoot.id])
        XCTAssertEqual(items.first?.folder?.name, "日本")
        XCTAssertEqual(items.first?.folder?.parent?.id, existingRoot.id)
    }

    @MainActor
    func testFolderImportUpdatesMovesAndFullyResetsExistingVideo() throws {
        let fixture = try LibraryFixture()
        let oldFolder = VideoFolder(name: "旧目录")
        fixture.context.insert(oldFolder)
        let oldDate = Date(timeIntervalSince1970: 1)
        let item = PlaylistItem(
            name: "旧名称",
            bookmarkData: Data([1]),
            sourceDisplayPath: "old.mp4",
            sourceIdentity: "same",
            sourceKind: .remote,
            addedAt: oldDate,
            lastPlayedAt: .now,
            lastPosition: 45,
            duration: 120,
            projection: .hemisphere180,
            stereoLayout: .sideBySide,
            thumbnailData: Data([9]),
            folder: oldFolder
        )
        fixture.context.insert(item)
        try fixture.context.save()
        let cache = RecordingCacheStore()

        let summary = try FolderImportService(modelContext: fixture.context, cacheStore: cache).apply(
            [fixture.preparedVideo(identity: "same", folders: ["新目录"], thumbnailData: Data([2]))],
            destination: nil
        )

        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(item.name, "视频-same")
        XCTAssertEqual(item.folder?.name, "新目录")
        XCTAssertGreaterThan(item.addedAt, oldDate)
        XCTAssertNil(item.lastPlayedAt)
        XCTAssertEqual(item.lastPosition, 0)
        XCTAssertEqual(item.duration, 0)
        XCTAssertEqual(item.projection, .sphere360)
        XCTAssertEqual(item.stereoLayout, .mono)
        XCTAssertEqual(item.thumbnailData, Data([2]))
        XCTAssertEqual(cache.removedIDs, [item.id])
    }

    @MainActor
    func testFolderImportDeduplicatesLegacyMatchesAndKeepsNewestItem() throws {
        let fixture = try LibraryFixture()
        let older = fixture.makeItem(name: "Older", sourceIdentity: "duplicate", addedAt: Date(timeIntervalSince1970: 1))
        let newer = fixture.makeItem(name: "Newer", sourceIdentity: "duplicate", addedAt: Date(timeIntervalSince1970: 2))
        fixture.context.insert(older)
        fixture.context.insert(newer)
        try fixture.context.save()
        let cache = RecordingCacheStore()

        let summary = try FolderImportService(modelContext: fixture.context, cacheStore: cache).apply(
            [fixture.preparedVideo(identity: "duplicate", folders: ["旅行"])],
            destination: nil
        )

        let items = try fixture.context.fetch(FetchDescriptor<PlaylistItem>())
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.deduplicated, 1)
        XCTAssertEqual(items.map(\.id), [newer.id])
        XCTAssertEqual(cache.removedIDs, Set([older.id, newer.id]))
    }

    @MainActor
    func testFolderImportProcessesDuplicateCandidatesOnlyOnce() throws {
        let fixture = try LibraryFixture()
        let prepared = fixture.preparedVideo(identity: "same-candidate", folders: ["旅行"])

        let summary = try FolderImportService(
            modelContext: fixture.context,
            cacheStore: RecordingCacheStore()
        ).apply([prepared, prepared], destination: nil)

        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<PlaylistItem>()).count, 1)
    }
}

private enum ThumbnailTestError: Error {
    case cannotAddInput
    case cannotStartWriting
    case cannotAppendFrame
    case cannotFinishWriting
    case missingPixelBufferPool
    case cannotCreatePixelBuffer
    case cannotCreateContext
}

@MainActor
private struct LibraryFixture {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        let schema = Schema([PlaylistItem.self, VideoFolder.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    func service(
        cacheStore: any MediaCacheRemoving = RecordingCacheStore()
    ) -> VideoLibraryService {
        VideoLibraryService(modelContext: context, cacheStore: cacheStore)
    }

    func makeItem(
        name: String,
        sourceIdentity: String? = nil,
        addedAt: Date = .now,
        thumbnailData: Data? = nil,
        folder: VideoFolder? = nil
    ) -> PlaylistItem {
        PlaylistItem(
            name: name,
            bookmarkData: Data(),
            sourceDisplayPath: "\(name).mp4",
            sourceIdentity: sourceIdentity,
            sourceKind: .local,
            addedAt: addedAt,
            thumbnailData: thumbnailData,
            folder: folder
        )
    }

    func preparedVideo(
        identity: String,
        folders: [String],
        thumbnailData: Data? = nil
    ) -> FolderImportPreparedVideo {
        FolderImportPreparedVideo(
            bookmarkData: Data([3]),
            sourceKind: .local,
            sourceIdentity: identity,
            sourceDisplayPath: (folders + ["视频-\(identity).mp4"]).joined(separator: "/"),
            name: "视频-\(identity)",
            folderComponents: folders,
            inspection: MediaInspection(
                container: "mp4",
                videoCodec: .h264,
                sampleEntries: ["avc1"],
                width: 3840,
                height: 2160,
                frameRate: 60,
                bitRate: 20_000_000,
                isHDR: false,
                audioCodecs: ["aac "],
                isSystemPlayable: true,
                hevcHardwareProbe: nil
            ),
            thumbnailData: thumbnailData
        )
    }
}

private final class RecordingCacheStore: MediaCacheRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private let shouldFail: Bool
    private var storedRemovedIDs: Set<UUID> = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    var removedIDs: Set<UUID> {
        lock.withLock { storedRemovedIDs }
    }

    func removeCachedData(for cacheKey: UUID) throws {
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = lock.withLock {
            storedRemovedIDs.insert(cacheKey)
        }
    }
}
