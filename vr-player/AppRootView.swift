import SwiftData
import SwiftUI

struct AppRootView: View {
    var body: some View {
        TabView {
            Tab("视频", systemImage: "play.rectangle") {
                ContentView()
            }

            Tab("设置", systemImage: "gearshape") {
                CacheSettingsView()
            }
        }
        .task {
            try? await Task.detached {
                try MediaCacheStore.shared.trimToGlobalLimit()
            }.value
        }
    }
}

#Preview {
    AppRootView()
        .modelContainer(for: [PlaylistItem.self, VideoFolder.self], inMemory: true)
}
