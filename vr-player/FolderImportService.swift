import Foundation
import SwiftData

nonisolated struct FolderImportCandidate: Equatable, Sendable {
    let url: URL
    let folderComponents: [String]

    var relativeDisplayPath: String {
        (folderComponents + [url.lastPathComponent]).joined(separator: "/")
    }
}

nonisolated enum FolderImportScanner {
    private static let supportedExtensions: Set<String> = ["mp4", "mov"]

    static func scan(directoryURL: URL) throws -> [FolderImportCandidate] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let rootValues = try directoryURL.resourceValues(forKeys: Set(keys))
        guard rootValues.isDirectory == true else {
            throw FolderImportError.notDirectory
        }

        let rootName = directoryURL.lastPathComponent
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw FolderImportError.cannotEnumerate
        }

        var candidates: [FolderImportCandidate] = []
        while let url = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                continue
            }
            if values.isSymbolicLink == true || values.isPackage == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isDirectory != true,
                  supportedExtensions.contains(url.pathExtension.lowercased())
            else { continue }

            let relativeDirectory = url.deletingLastPathComponent().pathComponents
                .dropFirst(directoryURL.pathComponents.count)
            candidates.append(
                FolderImportCandidate(
                    url: url,
                    folderComponents: [rootName] + relativeDirectory
                )
            )
        }
        return candidates.sorted {
            $0.relativeDisplayPath.localizedStandardCompare($1.relativeDisplayPath) == .orderedAscending
        }
    }
}

nonisolated enum MediaSourceIdentity {
    static func make(for url: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        if let values = try? url.resourceValues(forKeys: keys),
           let fileIdentifier = values.fileResourceIdentifier {
            let volume = values.volumeIdentifier.map { String(describing: $0) } ?? "unknown"
            return "resource:\(volume):\(String(describing: fileIdentifier))|url:\(url.standardizedFileURL.absoluteString)"
        }
        return "url:\(url.standardizedFileURL.absoluteString)"
    }

    @MainActor
    static func make(bookmarkData: Data) -> String? {
        guard let file = try? SecurityScopedFile(bookmarkData: bookmarkData) else { return nil }
        return make(for: file.url)
    }
}

nonisolated struct FolderImportPreparedVideo: Sendable {
    let bookmarkData: Data
    let sourceKind: MediaSourceKind
    let sourceIdentity: String
    let sourceDisplayPath: String
    let name: String
    let folderComponents: [String]
    let inspection: MediaInspection
    let thumbnailData: Data?
}

nonisolated struct FolderImportSkippedItem: Equatable, Sendable {
    let path: String
    let reason: String
}

nonisolated struct FolderImportProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case scanning
        case validating(current: Int, total: Int)
        case saving
    }

    let phase: Phase

    var message: String {
        switch phase {
        case .scanning:
            "正在扫描文件夹"
        case .validating(let current, let total):
            "正在检查视频 \(current)/\(total)"
        case .saving:
            "正在保存导入结果"
        }
    }
}

nonisolated struct FolderImportSummary: Equatable, Sendable {
    var added = 0
    var updated = 0
    var deduplicated = 0
    var skipped: [FolderImportSkippedItem] = []

    var title: String { "文件夹导入完成" }

    var message: String {
        var lines = ["新增 \(added) 个，更新 \(updated) 个，合并重复项 \(deduplicated) 个，跳过 \(skipped.count) 个。"]
        if !skipped.isEmpty {
            lines.append("")
            lines.append(contentsOf: skipped.prefix(12).map { "\($0.path)：\($0.reason)" })
            if skipped.count > 12 {
                lines.append("另有 \(skipped.count - 12) 个文件未显示。")
            }
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated struct FolderImportRisk: Identifiable, Sendable {
    let index: Int
    let path: String
    let warning: String

    var id: Int { index }
}

@MainActor
struct FolderImportService {
    private let modelContext: ModelContext
    private let cacheStore: any MediaCacheRemoving

    init(
        modelContext: ModelContext,
        cacheStore: any MediaCacheRemoving = MediaCacheStore.shared
    ) {
        self.modelContext = modelContext
        self.cacheStore = cacheStore
    }

    func importFolder(
        at directoryURL: URL,
        destination: VideoFolder?,
        progress: @MainActor (FolderImportProgress) -> Void,
        confirmRisks: @MainActor ([FolderImportRisk]) async -> Bool
    ) async throws -> FolderImportSummary {
        let didStartAccess = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }

        progress(FolderImportProgress(phase: .scanning))
        let candidates = try await Task.detached {
            try FolderImportScanner.scan(directoryURL: directoryURL)
        }.value

        var prepared: [FolderImportPreparedVideo] = []
        var skipped: [FolderImportSkippedItem] = []
        var risks: [FolderImportRisk] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            progress(FolderImportProgress(phase: .validating(current: index + 1, total: candidates.count)))
            do {
                let descriptor = try BookmarkAccess.prepareImport(for: candidate.url)
                let securedFile = try SecurityScopedFile(bookmarkData: descriptor.bookmarkData)
                let inspection = try await MediaImportValidator.validate(url: securedFile.url)
                let thumbnailData = await VideoThumbnailGenerator.generate(from: securedFile.url)
                let preparedIndex = prepared.count
                prepared.append(
                    FolderImportPreparedVideo(
                        bookmarkData: descriptor.bookmarkData,
                        sourceKind: descriptor.sourceKind,
                        sourceIdentity: MediaSourceIdentity.make(for: securedFile.url),
                        sourceDisplayPath: candidate.relativeDisplayPath,
                        name: candidate.url.deletingPathExtension().lastPathComponent,
                        folderComponents: candidate.folderComponents,
                        inspection: inspection,
                        thumbnailData: thumbnailData
                    )
                )
                if inspection.requiresCompatibilityConfirmation {
                    risks.append(
                        FolderImportRisk(
                            index: preparedIndex,
                            path: candidate.relativeDisplayPath,
                            warning: inspection.compatibilityWarning
                        )
                    )
                }
                _ = securedFile
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped.append(
                    FolderImportSkippedItem(
                        path: candidate.relativeDisplayPath,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        if !risks.isEmpty, !(await confirmRisks(risks)) {
            let rejectedIndices = Set(risks.map(\.index))
            for risk in risks {
                skipped.append(FolderImportSkippedItem(path: risk.path, reason: "用户跳过了兼容性风险视频。"))
            }
            prepared = prepared.enumerated().compactMap { rejectedIndices.contains($0.offset) ? nil : $0.element }
        }

        progress(FolderImportProgress(phase: .saving))
        var summary = try apply(prepared, destination: destination)
        summary.skipped = skipped
        return summary
    }

    func apply(
        _ preparedVideos: [FolderImportPreparedVideo],
        destination: VideoFolder?
    ) throws -> FolderImportSummary {
        var seenSourceIdentities: Set<String> = []
        let uniquePreparedVideos = preparedVideos.filter {
            seenSourceIdentities.insert($0.sourceIdentity).inserted
        }
        guard !uniquePreparedVideos.isEmpty else { return FolderImportSummary() }

        let allItems = try modelContext.fetch(FetchDescriptor<PlaylistItem>())
        var itemsByIdentity: [String: [PlaylistItem]] = [:]
        for item in allItems {
            let identity = item.sourceIdentity ?? MediaSourceIdentity.make(bookmarkData: item.bookmarkData)
            guard let identity else { continue }
            itemsByIdentity[identity, default: []].append(item)
        }

        let affectedItems = uniquePreparedVideos.flatMap { itemsByIdentity[$0.sourceIdentity] ?? [] }
        var cacheIDs: Set<UUID> = []
        for item in affectedItems where cacheIDs.insert(item.id).inserted {
            try cacheStore.removeCachedData(for: item.id)
        }

        do {
            var summary = FolderImportSummary()
            var folderCache = try folderLookup()
            for video in uniquePreparedVideos {
                let folder = folder(
                    for: video.folderComponents,
                    under: destination,
                    lookup: &folderCache
                )
                let matches = (itemsByIdentity[video.sourceIdentity] ?? [])
                    .sorted { $0.addedAt > $1.addedAt }
                if let survivor = matches.first {
                    survivor.resetForReimport(
                        name: video.name,
                        bookmarkData: video.bookmarkData,
                        sourceDisplayPath: video.sourceDisplayPath,
                        sourceIdentity: video.sourceIdentity,
                        sourceKind: video.sourceKind,
                        mediaInspection: video.inspection,
                        thumbnailData: video.thumbnailData,
                        folder: folder
                    )
                    for duplicate in matches.dropFirst() {
                        modelContext.delete(duplicate)
                    }
                    summary.updated += 1
                    summary.deduplicated += max(matches.count - 1, 0)
                    itemsByIdentity[video.sourceIdentity] = [survivor]
                } else {
                    let item = PlaylistItem(
                        name: video.name,
                        bookmarkData: video.bookmarkData,
                        sourceDisplayPath: video.sourceDisplayPath,
                        sourceIdentity: video.sourceIdentity,
                        sourceKind: video.sourceKind,
                        mediaInspection: video.inspection,
                        thumbnailData: video.thumbnailData,
                        folder: folder
                    )
                    modelContext.insert(item)
                    itemsByIdentity[video.sourceIdentity] = [item]
                    summary.added += 1
                }
            }
            try modelContext.save()
            return summary
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func folderLookup() throws -> [FolderKey: VideoFolder] {
        var lookup: [FolderKey: VideoFolder] = [:]
        for folder in try modelContext.fetch(FetchDescriptor<VideoFolder>())
            .sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = FolderKey(parentID: folder.parent?.id, name: Self.comparisonName(folder.name))
            lookup[key] = lookup[key] ?? folder
        }
        return lookup
    }

    private func folder(
        for components: [String],
        under destination: VideoFolder?,
        lookup: inout [FolderKey: VideoFolder]
    ) -> VideoFolder? {
        var parent = destination
        for component in components {
            let key = FolderKey(parentID: parent?.id, name: Self.comparisonName(component))
            if let existing = lookup[key] {
                parent = existing
            } else {
                let created = VideoFolder(name: component, parent: parent)
                modelContext.insert(created)
                lookup[key] = created
                parent = created
            }
        }
        return parent
    }

    private static func comparisonName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct FolderKey: Hashable {
    let parentID: UUID?
    let name: String
}

nonisolated enum FolderImportError: LocalizedError {
    case notDirectory
    case cannotEnumerate

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "所选项目不是文件夹。"
        case .cannotEnumerate:
            "无法读取所选文件夹。"
        }
    }
}
