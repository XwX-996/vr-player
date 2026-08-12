import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaylistItem.addedAt, order: .reverse) private var allItems: [PlaylistItem]
    @Query(sort: \VideoFolder.name) private var allFolders: [VideoFolder]

    @State private var path: [UUID] = []
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<LibraryEntryID> = []
    @State private var isImporting = false
    @State private var isImportingFolder = false
    @State private var isProcessingImport = false
    @State private var importProgressMessage = "正在检查视频"
    @State private var importDestinationID: UUID?
    @State private var playback: PlaybackPresentation?
    @State private var presentedSheet: LibrarySheet?
    @State private var deleteRequest: LibrarySelection?
    @State private var errorMessage: String?
    @State private var errorTitle = "操作失败"
    @State private var compatibilityWarning: CompatibilityWarning?
    @State private var compatibilityDecision: CheckedContinuation<Bool, Never>?
    @State private var folderImportSummary: FolderImportSummary?

    var body: some View {
        NavigationStack(path: $path) {
            directoryView(for: nil)
                .navigationDestination(for: UUID.self) { folderID in
                    if let folder = folder(withID: folderID) {
                        directoryView(for: folder)
                    } else {
                        ContentUnavailableView(
                            "文件夹不存在",
                            systemImage: "folder.badge.questionmark",
                            description: Text("该文件夹可能已经被删除。")
                        )
                    }
                }
        }
        .environment(\.editMode, $editMode)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode.isEditing || !selection.isEmpty {
                LibraryBatchActionBar(
                    selectionCount: selection.count,
                    onMove: presentMoveForSelection,
                    onDelete: requestSelectionDeletion
                )
            }
        }
        .alert("删除所选内容？", isPresented: batchDeletionBinding) {
            Button("取消", role: .cancel, action: cancelBatchDeletion)
            Button("删除", role: .destructive, action: performPendingDeletion)
        } message: {
            Text(deleteConfirmationMessage)
        }
        .onAppear {
            OrientationManager.lockPortrait()
        }
        .onChange(of: path) {
            finishEditing()
        }
        .onChange(of: currentDirectoryEntryIDs) { _, visibleEntryIDs in
            selection = LibrarySelectionLogic.pruned(selection, to: visibleEntryIDs)
        }
        .onDisappear {
            editMode = .inactive
            selection.removeAll()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .fileImporter(
            isPresented: $isImportingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
        .fullScreenCover(item: $playback, onDismiss: {
            OrientationManager.lockPortrait()
        }) { playback in
            PlayerScreen(item: playback.item, playlist: playback.playlist)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .createFolder(let parent):
                LibraryNameEditor(mode: .createFolder(parent: parent))
            case .renameFolder(let folder):
                LibraryNameEditor(mode: .renameFolder(folder))
            case .renameVideo(let item):
                LibraryNameEditor(mode: .renameVideo(item))
            case .move(let selectedFolders, let selectedItems):
                MoveDestinationView(
                    selectedFolders: selectedFolders,
                    selectedItems: selectedItems,
                    onMoved: finishEditing
                )
            }
        }
        .overlay {
            if isProcessingImport {
                ProgressView(importProgressMessage)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .alert(errorTitle, isPresented: errorBinding) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .alert("视频可能无法流畅播放", isPresented: compatibilityAlertBinding) {
            Button(compatibilityWarning?.isFolderBatch == true ? "跳过风险视频" : "取消", role: .cancel) {
                resolveCompatibilityWarning(addOriginal: false)
            }
            Button(compatibilityWarning?.isFolderBatch == true ? "全部仍然添加" : "仍然添加") {
                resolveCompatibilityWarning(addOriginal: true)
            }
        } message: {
            Text(compatibilityWarning?.message ?? "")
        }
        .alert(folderImportSummary?.title ?? "文件夹导入完成", isPresented: folderImportSummaryBinding) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(folderImportSummary?.message ?? "")
        }
    }

    private func directoryView(for folder: VideoFolder?) -> some View {
        let folders = folders(in: folder)
        let items = items(in: folder)
        return LibraryDirectoryView(
            folder: folder,
            folders: folders,
            items: items,
            editMode: $editMode,
            selection: $selection,
            deleteRequest: $deleteRequest,
            isImportDisabled: isProcessingImport,
            deleteConfirmationMessage: deleteConfirmationMessage,
            onAddVideo: { startImport(in: folder) },
            onImportFolder: { startFolderImport(in: folder) },
            onCreateFolder: { presentedSheet = .createFolder(parent: folder) },
            onPlay: { item in presentPlayer(item, playlist: items) },
            onRenameFolder: { presentedSheet = .renameFolder($0) },
            onRenameVideo: { presentedSheet = .renameVideo($0) },
            onMove: { folders, items in
                presentedSheet = .move(folders: folders, items: items)
            },
            onDelete: { folders, items in
                let anchor = folders.first.map { LibraryEntryID.folder($0.id) }
                    ?? items.first.map { LibraryEntryID.video($0.id) }
                deleteRequest = LibrarySelection(
                    folders: folders,
                    items: items,
                    anchor: anchor
                )
            },
            onConfirmDeletion: performPendingDeletion
        )
    }

    private func folders(in parent: VideoFolder?) -> [VideoFolder] {
        allFolders
            .filter { $0.parent?.id == parent?.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func items(in folder: VideoFolder?) -> [PlaylistItem] {
        allItems.filter { $0.folder?.id == folder?.id }
    }

    private func folder(withID id: UUID) -> VideoFolder? {
        allFolders.first { $0.id == id }
    }

    private var currentDirectoryEntryIDs: Set<LibraryEntryID> {
        let folderID = path.last
        let folderIDs = allFolders
            .filter { $0.parent?.id == folderID }
            .map { LibraryEntryID.folder($0.id) }
        let itemIDs = allItems
            .filter { $0.folder?.id == folderID }
            .map { LibraryEntryID.video($0.id) }
        return Set(folderIDs + itemIDs)
    }

    private func startImport(in folder: VideoFolder?) {
        importDestinationID = folder?.id
        isImporting = true
    }

    private func startFolderImport(in folder: VideoFolder?) {
        importDestinationID = folder?.id
        isImportingFolder = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            await importVideos(from: result, destinationID: importDestinationID)
        }
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            await importFolder(from: result, destinationID: importDestinationID)
        }
    }

    private func importFolder(
        from result: Result<[URL], Error>,
        destinationID: UUID?
    ) async {
        isProcessingImport = true
        importProgressMessage = "正在扫描文件夹"
        defer {
            isProcessingImport = false
            importDestinationID = nil
        }

        do {
            let destination = destinationID.flatMap(folder(withID:))
            guard destinationID == nil || destination != nil else {
                throw VideoImportError.destinationMissing
            }
            guard let directoryURL = try result.get().first else { return }
            let summary = try await FolderImportService(modelContext: modelContext).importFolder(
                at: directoryURL,
                destination: destination,
                progress: { progress in
                    importProgressMessage = progress.message
                },
                confirmRisks: { risks in
                    await confirmFolderCompatibility(risks)
                }
            )
            folderImportSummary = summary
        } catch is CancellationError {
            return
        } catch {
            errorTitle = "无法导入文件夹"
            errorMessage = error.localizedDescription
        }
    }

    private func importVideos(
        from result: Result<[URL], Error>,
        destinationID: UUID?
    ) async {
        isProcessingImport = true
        defer {
            isProcessingImport = false
            importDestinationID = nil
        }

        do {
            let destination = destinationID.flatMap(folder(withID:))
            guard destinationID == nil || destination != nil else {
                throw VideoImportError.destinationMissing
            }

            var preparedItems: [PlaylistItem] = []
            for url in try result.get() {
                do {
                    let descriptor = try BookmarkAccess.prepareImport(for: url)
                    let securedFile = try SecurityScopedFile(bookmarkData: descriptor.bookmarkData)
                    let inspection = try await MediaImportValidator.validate(url: securedFile.url)
                    if inspection.requiresCompatibilityConfirmation {
                        let accepted = await confirmCompatibility(
                            fileName: url.lastPathComponent,
                            inspection: inspection
                        )
                        guard accepted else { return }
                    }
                    let thumbnailData = await VideoThumbnailGenerator.generate(from: securedFile.url)
                    preparedItems.append(
                        PlaylistItem(
                            name: url.deletingPathExtension().lastPathComponent,
                            bookmarkData: descriptor.bookmarkData,
                            sourceDisplayPath: url.lastPathComponent,
                            sourceKind: descriptor.sourceKind,
                            mediaInspection: inspection,
                            thumbnailData: thumbnailData,
                            folder: destination
                        )
                    )
                    _ = securedFile
                } catch {
                    throw VideoImportError.fileFailed(name: url.lastPathComponent, underlying: error)
                }
            }
            for item in preparedItems {
                modelContext.insert(item)
            }
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        } catch {
            errorTitle = "无法添加视频"
            errorMessage = error.localizedDescription
        }
    }

    private func presentPlayer(_ item: PlaylistItem, playlist: [PlaylistItem]) {
        OrientationManager.lockLandscape()
        playback = PlaybackPresentation(item: item, playlist: playlist)
    }

    private func selectedContent() -> LibrarySelection {
        LibrarySelection(
            folders: allFolders.filter { selection.contains(.folder($0.id)) },
            items: allItems.filter { selection.contains(.video($0.id)) }
        )
    }

    private func presentMoveForSelection() {
        let selected = selectedContent()
        guard !selected.isEmpty else { return }
        presentedSheet = .move(folders: selected.folders, items: selected.items)
    }

    private func requestSelectionDeletion() {
        let selected = selectedContent()
        guard !selected.isEmpty else { return }
        deleteRequest = selected
    }

    private var batchDeletionBinding: Binding<Bool> {
        Binding(
            get: {
                guard let deleteRequest else { return false }
                return deleteRequest.anchor == nil
            },
            set: { isPresented in
                if !isPresented, deleteRequest?.anchor == nil {
                    deleteRequest = nil
                }
            }
        )
    }

    private func cancelBatchDeletion() {
        deleteRequest = nil
    }

    private func performPendingDeletion() {
        guard let deleteRequest else { return }
        do {
            try VideoLibraryService(modelContext: modelContext).delete(
                folders: deleteRequest.folders,
                items: deleteRequest.items
            )
            self.deleteRequest = nil
            finishEditing()
        } catch {
            self.deleteRequest = nil
            errorTitle = "无法删除"
            errorMessage = error.localizedDescription
        }
    }

    private func finishEditing() {
        editMode = .inactive
        selection.removeAll()
    }

    private var deleteConfirmationMessage: String {
        guard let deleteRequest else { return "" }
        let summary = deletionSummary(for: deleteRequest)
        if summary.folderCount > 0 {
            return "将删除 \(summary.folderCount) 个文件夹和 \(summary.videoCount) 个视频，并清除对应缓存。此操作无法撤销。"
        }
        return "将删除 \(summary.videoCount) 个视频，并清除对应缓存。此操作无法撤销。"
    }

    private func deletionSummary(for request: LibrarySelection) -> (folderCount: Int, videoCount: Int) {
        let selectedFolderIDs = Set(request.folders.map(\.id))
        let rootFolders = request.folders.filter { folder in
            var ancestor = folder.parent
            var visited: Set<UUID> = []
            while let current = ancestor, visited.insert(current.id).inserted {
                if selectedFolderIDs.contains(current.id) { return false }
                ancestor = current.parent
            }
            return true
        }

        var descendantFolderIDs: Set<UUID> = []
        var descendantVideoIDs: Set<UUID> = Set(request.items.map(\.id))
        var pending = rootFolders
        while let current = pending.popLast() {
            guard descendantFolderIDs.insert(current.id).inserted else { continue }
            descendantVideoIDs.formUnion(current.items.map(\.id))
            pending.append(contentsOf: current.children)
        }
        return (descendantFolderIDs.count, descendantVideoIDs.count)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var compatibilityAlertBinding: Binding<Bool> {
        Binding(
            get: { compatibilityWarning != nil },
            set: { isPresented in
                if !isPresented, compatibilityWarning != nil {
                    resolveCompatibilityWarning(addOriginal: false)
                }
            }
        )
    }

    private var folderImportSummaryBinding: Binding<Bool> {
        Binding(
            get: { folderImportSummary != nil },
            set: { if !$0 { folderImportSummary = nil } }
        )
    }

    private func confirmCompatibility(
        fileName: String,
        inspection: MediaInspection
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            compatibilityDecision = continuation
            compatibilityWarning = CompatibilityWarning(
                message: "\(fileName)\n\n\(inspection.compatibilityWarning)"
            )
        }
    }

    private func confirmFolderCompatibility(_ risks: [FolderImportRisk]) async -> Bool {
        let listedPaths = risks.prefix(8).map(\.path)
        var message = "发现 \(risks.count) 个可能无法流畅播放的 HEVC 视频：\n\n"
        message += listedPaths.joined(separator: "\n")
        if risks.count > listedPaths.count {
            message += "\n另有 \(risks.count - listedPaths.count) 个视频。"
        }
        message += "\n\n选择“跳过风险视频”将继续导入其余有效视频。"
        return await withCheckedContinuation { continuation in
            compatibilityDecision = continuation
            compatibilityWarning = CompatibilityWarning(message: message, isFolderBatch: true)
        }
    }

    private func resolveCompatibilityWarning(addOriginal: Bool) {
        let continuation = compatibilityDecision
        compatibilityDecision = nil
        compatibilityWarning = nil
        continuation?.resume(returning: addOriginal)
    }
}

private struct LibraryBatchActionBar: View {
    let selectionCount: Int
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onMove) {
                Image(systemName: "folder")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("移动")
            .disabled(selectionCount == 0)

            Spacer()

            Text("已选择 \(selectionCount) 项")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("删除")
            .disabled(selectionCount == 0)
        }
        .padding(.horizontal, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct LibraryDirectoryView: View {
    let folder: VideoFolder?
    let folders: [VideoFolder]
    let items: [PlaylistItem]
    @Binding var editMode: EditMode
    @Binding var selection: Set<LibraryEntryID>
    @Binding var deleteRequest: LibrarySelection?
    let isImportDisabled: Bool
    let deleteConfirmationMessage: String
    let onAddVideo: () -> Void
    let onImportFolder: () -> Void
    let onCreateFolder: () -> Void
    let onPlay: (PlaylistItem) -> Void
    let onRenameFolder: (VideoFolder) -> Void
    let onRenameVideo: (PlaylistItem) -> Void
    let onMove: ([VideoFolder], [PlaylistItem]) -> Void
    let onDelete: ([VideoFolder], [PlaylistItem]) -> Void
    let onConfirmDeletion: () -> Void

    var body: some View {
        Group {
            if folders.isEmpty && items.isEmpty {
                emptyState
            } else {
                libraryList
            }
        }
        .navigationTitle(folder?.name ?? "视频")
        .navigationBarTitleDisplayMode(folder == nil ? .large : .inline)
        .toolbar {
            if editMode.isEditing || !folders.isEmpty || !items.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "完成" : "编辑", action: toggleEditing)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if editMode.isEditing {
                    Button(allVisibleEntriesSelected ? "取消全选" : "全选", action: toggleAllEntries)
                        .disabled(visibleEntryIDs.isEmpty)
                } else {
                    Menu {
                        Button("添加视频", systemImage: "video.badge.plus", action: onAddVideo)
                            .disabled(isImportDisabled)
                        Button("导入文件夹", systemImage: "folder.badge.plus", action: onImportFolder)
                            .disabled(isImportDisabled)
                        Button("新建文件夹", systemImage: "folder.badge.plus", action: onCreateFolder)
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
        }
    }

    private var libraryList: some View {
        List {
            if !folders.isEmpty {
                Section("文件夹") {
                    ForEach(folders) { folder in
                        folderEntry(folder)
                    }
                }
            }

            if !items.isEmpty {
                Section("视频") {
                    ForEach(items) { item in
                        videoEntry(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func folderEntry(_ folder: VideoFolder) -> some View {
        Group {
            if editMode.isEditing {
                LibrarySelectionRow(
                    entryID: .folder(folder.id),
                    accessibilityLabel: folder.name,
                    selection: $selection
                ) {
                    FolderRow(folder: folder)
                }
                    .contextMenu {
                        folderActions(folder)
                    }
            } else {
                NavigationLink(value: folder.id) {
                    FolderRow(folder: folder)
                }
                .tag(LibraryEntryID.folder(folder.id))
                .contextMenu {
                    folderActions(folder)
                }
            }
        }
        .deleteConfirmationPopover(
            isPresented: deletionBinding(for: .folder(folder.id)),
            message: deleteConfirmationMessage,
            onDelete: onConfirmDeletion,
            onCancel: cancelDeletion
        )
    }

    @ViewBuilder
    private func videoEntry(_ item: PlaylistItem) -> some View {
        Group {
            if editMode.isEditing {
                LibrarySelectionRow(
                    entryID: .video(item.id),
                    accessibilityLabel: item.name,
                    selection: $selection
                ) {
                    PlaylistRow(item: item)
                }
                    .contextMenu {
                        videoActions(item)
                    }
            } else {
                Button {
                    onPlay(item)
                } label: {
                    PlaylistRow(item: item)
                }
                .buttonStyle(.plain)
                .tag(LibraryEntryID.video(item.id))
                .contextMenu {
                    videoActions(item)
                }
            }
        }
        .deleteConfirmationPopover(
            isPresented: deletionBinding(for: .video(item.id)),
            message: deleteConfirmationMessage,
            onDelete: onConfirmDeletion,
            onCancel: cancelDeletion
        )
    }

    private var visibleEntryIDs: Set<LibraryEntryID> {
        let folderIDs = folders.map { LibraryEntryID.folder($0.id) }
        let itemIDs = items.map { LibraryEntryID.video($0.id) }
        return Set(folderIDs + itemIDs)
    }

    private var allVisibleEntriesSelected: Bool {
        LibrarySelectionLogic.allSelected(visibleEntryIDs, in: selection)
    }

    private func toggleEditing() {
        if editMode.isEditing {
            editMode = .inactive
            selection.removeAll()
        } else {
            selection.removeAll()
            editMode = .active
        }
    }

    private func toggleAllEntries() {
        selection = LibrarySelectionLogic.togglingAll(visibleEntryIDs, in: selection)
    }

    private func deletionBinding(for anchor: LibraryEntryID?) -> Binding<Bool> {
        Binding(
            get: {
                guard let deleteRequest else { return false }
                return deleteRequest.anchor == anchor
            },
            set: { isPresented in
                if !isPresented, deleteRequest?.anchor == anchor {
                    deleteRequest = nil
                }
            }
        )
    }

    private func cancelDeletion() {
        deleteRequest = nil
    }

    @ViewBuilder
    private func folderActions(_ folder: VideoFolder) -> some View {
        itemActions(
            onRename: { onRenameFolder(folder) },
            onMove: { onMove([folder], []) },
            onDelete: { onDelete([folder], []) }
        )
    }

    @ViewBuilder
    private func videoActions(_ item: PlaylistItem) -> some View {
        itemActions(
            onRename: { onRenameVideo(item) },
            onMove: { onMove([], [item]) },
            onDelete: { onDelete([], [item]) }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("文件夹是空的", systemImage: "folder")
        } description: {
            Text("添加视频或创建子文件夹来整理内容。")
        } actions: {
            Button("添加视频", systemImage: "video.badge.plus", action: onAddVideo)
                .buttonStyle(.borderedProminent)
                .disabled(isImportDisabled)
            Button("导入文件夹", systemImage: "folder.badge.plus", action: onImportFolder)
                .buttonStyle(.bordered)
                .disabled(isImportDisabled)
            Button("新建文件夹", systemImage: "folder.badge.plus", action: onCreateFolder)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func itemActions(
        onRename: @escaping () -> Void,
        onMove: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        Button("重命名", systemImage: "pencil", action: onRename)
        Button("移动", systemImage: "folder", action: onMove)
        Divider()
        Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

private struct FolderRow: View {
    let folder: VideoFolder

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(folder.children.count) 个文件夹，\(folder.items.count) 个视频")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct PlaylistRow: View {
    let item: PlaylistItem

    var body: some View {
        HStack(spacing: 14) {
            VideoThumbnailView(data: item.thumbnailData)

            VStack(alignment: .leading, spacing: 7) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Label(
                    item.sourceKind == .remote ? "SMB" : "本地",
                    systemImage: item.sourceKind == .remote ? "network" : "iphone"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if item.lastPosition > 0 {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                }
            }

            Spacer(minLength: 8)

            if item.lastPosition > 0 {
                Text(MediaTime.text(item.lastPosition))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct VideoThumbnailView: View {
    @State private var thumbnail: UIImage?

    init(data: Data?) {
        _thumbnail = State(initialValue: data.flatMap(UIImage.init(data:)))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.secondarySystemFill))

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()

                Circle()
                    .fill(.black.opacity(0.45))
                    .frame(width: 24, height: 24)

                Image(systemName: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .offset(x: 1)
            } else {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

private struct LibraryNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mode: Mode
    @State private var name: String
    @State private var errorMessage: String?

    init(mode: Mode) {
        self.mode = mode
        _name = State(initialValue: mode.initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(mode.fieldTitle, text: $name)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert("无法保存", isPresented: errorBinding) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func save() {
        do {
            let service = VideoLibraryService(modelContext: modelContext)
            switch mode {
            case .createFolder(let parent):
                try service.createFolder(named: name, in: parent)
            case .renameFolder(let folder):
                try service.rename(folder, to: name)
            case .renameVideo(let item):
                try service.rename(item, to: name)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    enum Mode {
        case createFolder(parent: VideoFolder?)
        case renameFolder(VideoFolder)
        case renameVideo(PlaylistItem)

        var initialName: String {
            switch self {
            case .createFolder: ""
            case .renameFolder(let folder): folder.name
            case .renameVideo(let item): item.name
            }
        }

        var title: String {
            switch self {
            case .createFolder: "新建文件夹"
            case .renameFolder: "重命名文件夹"
            case .renameVideo: "重命名视频"
            }
        }

        var fieldTitle: String {
            switch self {
            case .createFolder, .renameFolder: "文件夹名称"
            case .renameVideo: "视频名称"
            }
        }
    }
}

private struct MoveDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VideoFolder.name) private var allFolders: [VideoFolder]

    let selectedFolders: [VideoFolder]
    let selectedItems: [PlaylistItem]
    let onMoved: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Button {
                    move(to: nil)
                } label: {
                    destinationRow(name: "首页", depth: 0, systemImage: "house")
                }
                .buttonStyle(.plain)

                ForEach(availableDestinations) { destination in
                    Button {
                        move(to: destination.folder)
                    } label: {
                        destinationRow(
                            name: destination.folder.name,
                            depth: destination.depth,
                            systemImage: "folder"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) {
                        dismiss()
                    }
                }
            }
        }
        .alert("无法移动", isPresented: errorBinding) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var availableDestinations: [FolderDestination] {
        let selectedFolderIDs = Set(selectedFolders.map(\.id))
        let validFolders = allFolders.filter { folder in
            var current: VideoFolder? = folder
            var visited: Set<UUID> = []
            while let candidate = current, visited.insert(candidate.id).inserted {
                if selectedFolderIDs.contains(candidate.id) {
                    return false
                }
                current = candidate.parent
            }
            return true
        }

        let validIDs = Set(validFolders.map(\.id))
        let roots = validFolders
            .filter { $0.parent == nil || !validIDs.contains($0.parent?.id ?? UUID()) }
            .sorted(by: folderNameOrder)
        var result: [FolderDestination] = []
        var visited: Set<UUID> = []

        func append(_ folder: VideoFolder, depth: Int) {
            guard visited.insert(folder.id).inserted else { return }
            result.append(FolderDestination(folder: folder, depth: depth))
            validFolders
                .filter { $0.parent?.id == folder.id }
                .sorted(by: folderNameOrder)
                .forEach { append($0, depth: depth + 1) }
        }

        roots.forEach { append($0, depth: 0) }
        return result
    }

    private func folderNameOrder(_ lhs: VideoFolder, _ rhs: VideoFolder) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func destinationRow(name: String, depth: Int, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: CGFloat(depth) * 20)
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(name)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func move(to destination: VideoFolder?) {
        do {
            try VideoLibraryService(modelContext: modelContext).move(
                folders: selectedFolders,
                items: selectedItems,
                to: destination
            )
            onMoved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

nonisolated enum LibraryEntryID: Hashable, Sendable {
    case folder(UUID)
    case video(UUID)
}

nonisolated enum LibrarySelectionLogic {
    static func toggling(_ entryID: LibraryEntryID, in selection: Set<LibraryEntryID>) -> Set<LibraryEntryID> {
        var updatedSelection = selection
        if updatedSelection.remove(entryID) == nil {
            updatedSelection.insert(entryID)
        }
        return updatedSelection
    }

    static func allSelected(
        _ visibleEntryIDs: Set<LibraryEntryID>,
        in selection: Set<LibraryEntryID>
    ) -> Bool {
        !visibleEntryIDs.isEmpty && visibleEntryIDs.isSubset(of: selection)
    }

    static func togglingAll(
        _ visibleEntryIDs: Set<LibraryEntryID>,
        in selection: Set<LibraryEntryID>
    ) -> Set<LibraryEntryID> {
        if allSelected(visibleEntryIDs, in: selection) {
            return []
        }
        return visibleEntryIDs
    }

    static func pruned(
        _ selection: Set<LibraryEntryID>,
        to visibleEntryIDs: Set<LibraryEntryID>
    ) -> Set<LibraryEntryID> {
        selection.intersection(visibleEntryIDs)
    }
}

private struct LibrarySelectionRow<Content: View>: View {
    let entryID: LibraryEntryID
    let accessibilityLabel: String
    @Binding var selection: Set<LibraryEntryID>
    @ViewBuilder let content: () -> Content

    private var isSelected: Bool {
        selection.contains(entryID)
    }

    var body: some View {
        Button(action: toggleSelection) {
            HStack(spacing: 0) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAction(named: isSelected ? "取消选择" : "选择", toggleSelection)
    }

    private func toggleSelection() {
        selection = LibrarySelectionLogic.toggling(entryID, in: selection)
    }
}

private struct LibrarySelection {
    let folders: [VideoFolder]
    let items: [PlaylistItem]
    var anchor: LibraryEntryID? = nil

    var isEmpty: Bool {
        folders.isEmpty && items.isEmpty
    }
}

private extension View {
    func deleteConfirmationPopover(
        isPresented: Binding<Bool>,
        message: String,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 16) {
                Text("删除所选内容？")
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("取消", role: .cancel, action: onCancel)
                    Button("删除", role: .destructive, action: onDelete)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            .padding(20)
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private enum LibrarySheet: Identifiable {
    case createFolder(parent: VideoFolder?)
    case renameFolder(VideoFolder)
    case renameVideo(PlaylistItem)
    case move(folders: [VideoFolder], items: [PlaylistItem])

    var id: String {
        switch self {
        case .createFolder(let parent): "create-folder-\(parent?.id.uuidString ?? "root")"
        case .renameFolder(let folder): "rename-folder-\(folder.id)"
        case .renameVideo(let item): "rename-video-\(item.id)"
        case .move: "move"
        }
    }
}

private struct PlaybackPresentation: Identifiable {
    let item: PlaylistItem
    let playlist: [PlaylistItem]

    var id: UUID { item.id }
}

private struct FolderDestination: Identifiable {
    let folder: VideoFolder
    let depth: Int

    var id: UUID { folder.id }
}

private struct CompatibilityWarning: Equatable {
    let message: String
    let isFolderBatch: Bool

    init(message: String, isFolderBatch: Bool = false) {
        self.message = message
        self.isFolderBatch = isFolderBatch
    }
}

private enum VideoImportError: LocalizedError {
    case destinationMissing
    case fileFailed(name: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .destinationMissing:
            "目标文件夹已不存在，请重新选择。"
        case .fileFailed(let name, let underlying):
            "\(name)：\(underlying.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [PlaylistItem.self, VideoFolder.self], inMemory: true)
}
