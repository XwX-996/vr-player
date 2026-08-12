import Foundation
import SwiftData

nonisolated protocol MediaCacheRemoving: Sendable {
    func removeCachedData(for cacheKey: UUID) throws
}

extension MediaCacheStore: MediaCacheRemoving {}

@MainActor
struct VideoLibraryService {
    private let modelContext: ModelContext
    private let cacheStore: any MediaCacheRemoving

    init(
        modelContext: ModelContext,
        cacheStore: any MediaCacheRemoving = MediaCacheStore.shared
    ) {
        self.modelContext = modelContext
        self.cacheStore = cacheStore
    }

    @discardableResult
    func createFolder(named proposedName: String, in parent: VideoFolder?) throws -> VideoFolder {
        let name = try validatedName(proposedName)
        try ensureFolderNameIsAvailable(name, in: parent)

        let folder = VideoFolder(name: name, parent: parent)
        modelContext.insert(folder)
        try saveOrRollback()
        return folder
    }

    func rename(_ folder: VideoFolder, to proposedName: String) throws {
        let name = try validatedName(proposedName)
        try ensureFolderNameIsAvailable(name, in: folder.parent, excluding: folder.id)
        folder.name = name
        try saveOrRollback()
    }

    func rename(_ item: PlaylistItem, to proposedName: String) throws {
        item.name = try validatedName(proposedName)
        try saveOrRollback()
    }

    func move(
        folders: [VideoFolder],
        items: [PlaylistItem],
        to destination: VideoFolder?
    ) throws {
        let uniqueFolders = folders.uniqued(by: \.id)
        let uniqueItems = items.uniqued(by: \.id)

        for folder in uniqueFolders {
            guard folder.id != destination?.id,
                  !folder.containsDescendant(destination)
            else {
                throw VideoLibraryError.invalidMove
            }
        }

        let movingFolderIDs = Set(uniqueFolders.map(\.id))
        var destinationNames = try allFolders()
            .filter { $0.parent?.id == destination?.id && !movingFolderIDs.contains($0.id) }
            .map { Self.comparisonName($0.name) }
        for folder in uniqueFolders {
            let comparisonName = Self.comparisonName(folder.name)
            guard !destinationNames.contains(comparisonName) else {
                throw VideoLibraryError.duplicateFolderName(folder.name)
            }
            destinationNames.append(comparisonName)
        }

        uniqueFolders.forEach { $0.parent = destination }
        uniqueItems.forEach { $0.folder = destination }
        try saveOrRollback()
    }

    func delete(folders: [VideoFolder], items: [PlaylistItem]) throws {
        let selectedFolderIDs = Set(folders.map(\.id))
        let rootFolders = folders
            .uniqued(by: \.id)
            .filter { !hasSelectedAncestor($0, selectedFolderIDs: selectedFolderIDs) }

        let folderItems = rootFolders.flatMap(\.allDescendantItems)
        let coveredItemIDs = Set(folderItems.map(\.id))
        let directItems = items
            .uniqued(by: \.id)
            .filter { !coveredItemIDs.contains($0.id) }
        let allItems = (folderItems + directItems).uniqued(by: \.id)

        var cacheFailures: [String] = []
        for item in allItems {
            do {
                try cacheStore.removeCachedData(for: item.id)
            } catch {
                cacheFailures.append(item.name)
            }
        }
        guard cacheFailures.isEmpty else {
            throw VideoLibraryError.cacheDeletionFailed(cacheFailures)
        }

        directItems.forEach(modelContext.delete)
        rootFolders.forEach(modelContext.delete)
        try saveOrRollback()
    }

    private func ensureFolderNameIsAvailable(
        _ name: String,
        in parent: VideoFolder?,
        excluding excludedID: UUID? = nil
    ) throws {
        let comparisonName = Self.comparisonName(name)
        let duplicate = try allFolders().contains {
            $0.id != excludedID
                && $0.parent?.id == parent?.id
                && Self.comparisonName($0.name) == comparisonName
        }
        guard !duplicate else {
            throw VideoLibraryError.duplicateFolderName(name)
        }
    }

    private func allFolders() throws -> [VideoFolder] {
        try modelContext.fetch(FetchDescriptor<VideoFolder>())
    }

    private func hasSelectedAncestor(
        _ folder: VideoFolder,
        selectedFolderIDs: Set<UUID>
    ) -> Bool {
        var ancestor = folder.parent
        var visited: Set<UUID> = []
        while let current = ancestor, visited.insert(current.id).inserted {
            if selectedFolderIDs.contains(current.id) {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    private func validatedName(_ proposedName: String) throws -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw VideoLibraryError.emptyName
        }
        return name
    }

    private static func comparisonName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

enum VideoLibraryError: LocalizedError, Equatable {
    case emptyName
    case duplicateFolderName(String)
    case invalidMove
    case cacheDeletionFailed([String])

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "名称不能为空。"
        case .duplicateFolderName(let name):
            "当前目录中已存在名为“\(name)”的文件夹。"
        case .invalidMove:
            "文件夹不能移动到自身或它的子文件夹中。"
        case .cacheDeletionFailed(let names):
            "无法清除以下视频的缓存：\(names.joined(separator: "、"))。"
        }
    }
}

private extension VideoFolder {
    func containsDescendant(_ candidate: VideoFolder?) -> Bool {
        guard let candidate else { return false }
        var ancestor = candidate.parent
        var visited: Set<UUID> = []
        while let current = ancestor, visited.insert(current.id).inserted {
            if current.id == id {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    var allDescendantItems: [PlaylistItem] {
        var result = items
        var pending = children
        var visited: Set<UUID> = [id]
        while let folder = pending.popLast() {
            guard visited.insert(folder.id).inserted else { continue }
            result.append(contentsOf: folder.items)
            pending.append(contentsOf: folder.children)
        }
        return result
    }
}

private extension Sequence {
    func uniqued<ID: Hashable>(by identifier: (Element) -> ID) -> [Element] {
        var seen: Set<ID> = []
        return filter { seen.insert(identifier($0)).inserted }
    }
}
