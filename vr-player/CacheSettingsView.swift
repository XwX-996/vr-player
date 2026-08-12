import SwiftUI

struct CacheSettingsView: View {
    @AppStorage(CacheStorageSettings.limitMegabytesKey)
    private var limitMegabytes = CacheStorageSettings.defaultMegabytes

    @State private var cachedBytes: Int64 = 0
    @State private var isAdjustingLimit = false
    @State private var isClearingCache = false
    @State private var showsClearConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("当前缓存") {
                        Text(formattedBytes(cachedBytes))
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("缓存上限")
                            Spacer()
                            Text(formattedBytes(CacheStorageSettings.bytes(forMegabytes: limitMegabytes)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: limitBinding,
                            in: CacheStorageSettings.minimumMegabytes...CacheStorageSettings.maximumMegabytes,
                            step: CacheStorageSettings.stepMegabytes,
                            onEditingChanged: handleLimitEditingChanged
                        )
                        .accessibilityLabel("缓存上限")
                        .accessibilityValue(
                            formattedBytes(CacheStorageSettings.bytes(forMegabytes: limitMegabytes))
                        )
                    }
                    .padding(.vertical, 4)

                    Button("清除全部缓存", systemImage: "trash", role: .destructive) {
                        showsClearConfirmation = true
                    }
                    .disabled(isClearingCache || cachedBytes == 0)
                } header: {
                    Text("存储空间")
                } footer: {
                    Text("远程视频的单项缓存最多占用 256 MB。达到总上限时会自动清理最久未使用的视频缓存，不会删除播放列表或源文件。")
                }
            }
            .navigationTitle("设置")
        }
        .task {
            normalizeStoredLimit()
            await trimAndRefresh()
        }
        .confirmationDialog(
            "清除全部缓存？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除全部缓存", role: .destructive) {
                clearAllCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作只会删除远程视频缓存，播放列表、播放进度和源文件都会保留。")
        }
        .alert("缓存操作失败", isPresented: errorBinding) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var limitBinding: Binding<Double> {
        Binding(
            get: { limitMegabytes },
            set: { limitMegabytes = CacheStorageSettings.normalizedMegabytes($0) }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func handleLimitEditingChanged(_ isEditing: Bool) {
        isAdjustingLimit = isEditing
        guard !isEditing else { return }
        Task {
            await trimAndRefresh()
        }
    }

    private func normalizeStoredLimit() {
        limitMegabytes = CacheStorageSettings.normalizedMegabytes(limitMegabytes)
    }

    private func trimAndRefresh() async {
        guard !isAdjustingLimit else { return }
        do {
            let bytes = try await Task.detached {
                try MediaCacheStore.shared.trimToGlobalLimit()
                return try MediaCacheStore.shared.totalCachedBytes()
            }.value
            cachedBytes = bytes
        } catch {
            errorMessage = error.localizedDescription
            await refreshCachedBytes()
        }
    }

    private func clearAllCache() {
        isClearingCache = true
        Task {
            defer { isClearingCache = false }
            do {
                let bytes = try await Task.detached {
                    try MediaCacheStore.shared.removeAllCachedData()
                    return try MediaCacheStore.shared.totalCachedBytes()
                }.value
                cachedBytes = bytes
            } catch {
                errorMessage = error.localizedDescription
                await refreshCachedBytes()
            }
        }
    }

    private func refreshCachedBytes() async {
        do {
            cachedBytes = try await Task.detached {
                try MediaCacheStore.shared.totalCachedBytes()
            }.value
        } catch {
            cachedBytes = 0
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

#Preview {
    CacheSettingsView()
}
