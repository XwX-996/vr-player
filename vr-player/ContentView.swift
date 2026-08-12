import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaylistItem.addedAt, order: .reverse) private var items: [PlaylistItem]

    @State private var isImporting = false
    @State private var isProcessingImport = false
    @State private var selectedItem: PlaylistItem?
    @State private var importError: String?
    @State private var errorTitle = "Could not add video"

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    playlist
                }
            }
            .navigationTitle("VR Player")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add video", systemImage: "plus") {
                        isImporting = true
                    }
                    .disabled(isProcessingImport)
                }
            }
        }
        .onAppear {
            OrientationManager.lockPortrait()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .fullScreenCover(item: $selectedItem, onDismiss: {
            OrientationManager.lockPortrait()
        }) { item in
            PlayerScreen(item: item, playlist: items)
        }
        .overlay {
            if isProcessingImport {
                ProgressView("Checking videos")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .alert(errorTitle, isPresented: importAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Unknown error")
        }
    }

    private var playlist: some View {
        List {
            Section {
                ForEach(items) { item in
                    Button {
                        presentPlayer(item)
                    } label: {
                        PlaylistRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteItems)
            } header: {
                Text("\(items.count) video\(items.count == 1 ? "" : "s")")
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No videos", systemImage: "play.rectangle.on.rectangle")
        } description: {
            Text("Choose a local video or a video from an SMB server connected in Files.")
        } actions: {
            Button("Add video", systemImage: "plus") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessingImport)
        }
    }

    private var importAlertBinding: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            await importVideos(from: result)
        }
    }

    private func importVideos(from result: Result<[URL], Error>) async {
        isProcessingImport = true
        defer { isProcessingImport = false }

        do {
            var preparedItems: [PlaylistItem] = []
            for url in try result.get() {
                do {
                    let descriptor = try BookmarkAccess.prepareImport(for: url)
                    let securedFile = try SecurityScopedFile(bookmarkData: descriptor.bookmarkData)
                    try await MediaImportValidator.validate(url: securedFile.url)
                    preparedItems.append(
                        PlaylistItem(
                            name: url.deletingPathExtension().lastPathComponent,
                            bookmarkData: descriptor.bookmarkData,
                            sourceDisplayPath: url.lastPathComponent,
                            sourceKind: descriptor.sourceKind
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
            errorTitle = "Could not add video"
            importError = error.localizedDescription
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let selectedItems = offsets.compactMap { index in
            items.indices.contains(index) ? items[index] : nil
        }
        var cacheDeletionFailures: [String] = []

        for item in selectedItems {
            do {
                try ByteRangeCache.removeCachedData(for: item.id)
                modelContext.delete(item)
            } catch {
                cacheDeletionFailures.append(item.name)
            }
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            errorTitle = "Could not delete video"
            importError = error.localizedDescription
            return
        }

        if !cacheDeletionFailures.isEmpty {
            errorTitle = "Could not delete video"
            importError = "Cached data could not be removed for: \(cacheDeletionFailures.joined(separator: ", "))."
        }
    }

    private func presentPlayer(_ item: PlaylistItem) {
        OrientationManager.lockLandscape()
        selectedItem = item
    }
}

private enum VideoImportError: LocalizedError {
    case fileFailed(name: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .fileFailed(let name, let underlying):
            "\(name): \(underlying.localizedDescription)"
        }
    }
}

private struct PlaylistRow: View {
    let item: PlaylistItem

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.secondarySystemFill))
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 76, height: 48)

            VStack(alignment: .leading, spacing: 7) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Label(item.sourceKind == .remote ? "SMB" : "Local", systemImage: item.sourceKind == .remote ? "network" : "iphone")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if item.lastPosition > 0 {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                if item.lastPosition > 0 {
                    Text(MediaTime.text(item.lastPosition))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

#Preview {
    ContentView()
        .modelContainer(for: PlaylistItem.self, inMemory: true)
}
