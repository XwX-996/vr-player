import SwiftData
import SwiftUI
import UIKit

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    let playlist: [PlaylistItem]

    @State private var currentItem: PlaylistItem
    @State private var session: PlayerSession?
    @State private var renderer: VRMetalRenderer?
    @State private var setupError: String?
    @State private var hudMode: VRHUDMode = .main
    @State private var playlistPage = 0
    @State private var volumeController = SystemVolumeController()
    @State private var brightnessController = ScreenBrightnessController()
    @State private var recenterRequestID: UUID?
    @State private var recenterCountdown: Int?

    private let playlistPageSize = 5
    private let recenterCountdownStart = 3

    init(item: PlaylistItem, playlist: [PlaylistItem]) {
        self.playlist = playlist
        _currentItem = State(initialValue: item)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session {
                VRMetalSurface(
                    frameProvider: session.frameProvider,
                    settings: VRRenderSettings(
                        projection: currentItem.projection,
                        stereoLayout: currentItem.stereoLayout
                    ),
                    hudState: makeHUDState(session: session),
                    actionHandler: { activation in
                        Task { @MainActor in
                            handle(activation)
                        }
                    }
                ) { renderer in
                    DispatchQueue.main.async {
                        self.renderer = renderer
                    }
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard recenterCountdown == nil else { return }
                    renderer?.showControls()
                }

                if session.phase == .preparing || session.phase == .buffering {
                    binocularStatus(title: session.phase.title)
                }
                if case .failed(let message) = session.phase {
                    errorOverlay(message: message)
                }
            } else if let setupError {
                errorOverlay(message: setupError)
            } else {
                binocularStatus(title: "Preparing")
            }

            SystemVolumeHostView(controller: volumeController)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)

            ScreenBrightnessHostView(controller: brightnessController)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            OrientationManager.lockLandscape()
            UIApplication.shared.isIdleTimerDisabled = true
            open(currentItem)
        }
        .task(id: recenterRequestID) {
            guard recenterRequestID != nil else {
                recenterCountdown = nil
                return
            }

            for value in stride(from: recenterCountdownStart, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                recenterCountdown = value
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled, scenePhase == .active else {
                recenterCountdown = nil
                return
            }
            recenterCountdown = nil
            renderer?.recenter()
        }
        .onDisappear {
            session?.shutdown()
            renderer?.pauseTracking()
            UIApplication.shared.isIdleTimerDisabled = false
            try? modelContext.save()
            OrientationManager.lockPortrait()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                renderer?.resumeTracking()
            } else {
                recenterRequestID = nil
                renderer?.pauseTracking()
                session?.persistState()
                try? modelContext.save()
            }
        }
    }

    private func makeHUDState(session: PlayerSession) -> VRHUDState {
        let pageCount = max(Int(ceil(Double(playlist.count) / Double(playlistPageSize))), 1)
        let safePage = min(max(playlistPage, 0), pageCount - 1)
        let start = min(safePage * playlistPageSize, playlist.count)
        let end = min(start + playlistPageSize, playlist.count)
        let entries = playlist[start..<end].map {
            VRPlaylistEntry(id: $0.id, name: $0.name, isCurrent: $0.id == currentItem.id)
        }
        return VRHUDState(
            mode: hudMode,
            isPlaying: session.isPlaying,
            position: session.position,
            duration: session.duration,
            bufferedFraction: session.bufferedFraction,
            projection: currentItem.projection,
            stereoLayout: currentItem.stereoLayout,
            brightness: brightnessController.brightness,
            volume: volumeController.volume,
            playlistEntries: entries,
            playlistPage: safePage,
            playlistPageCount: pageCount,
            recenterCountdown: recenterCountdown
        )
    }

    private func handle(_ activation: VRControlActivation) {
        guard let session else { return }
        switch activation.target {
        case .back:
            closePlayer()
        case .hideControls:
            renderer?.hideControls()
        case .recenter:
            renderer?.hideControls()
            recenterCountdown = recenterCountdownStart
            recenterRequestID = UUID()
        case .previous:
            switchRelative(by: -1)
        case .playPause:
            session.togglePlayback()
        case .next:
            switchRelative(by: 1)
        case .playlist:
            hudMode = .playlist
            playlistPage = (playlist.firstIndex(where: { $0.id == currentItem.id }) ?? 0) / playlistPageSize
        case .seek:
            if let fraction = activation.value {
                session.seek(to: fraction * session.duration)
            }
        case .projection180:
            currentItem.projection = .hemisphere180
            saveItemSettings()
        case .projection360:
            currentItem.projection = .sphere360
            saveItemSettings()
        case .mono:
            currentItem.stereoLayout = .mono
            saveItemSettings()
        case .sideBySide:
            currentItem.stereoLayout = .sideBySide
            saveItemSettings()
        case .brightness:
            if let value = activation.value {
                brightnessController.setBrightness(value)
            }
        case .volume:
            if let value = activation.value {
                volumeController.setVolume(value)
            }
        case .playlistBack:
            hudMode = .main
        case .playlistPreviousPage:
            playlistPage = max(playlistPage - 1, 0)
        case .playlistNextPage:
            let pageCount = max(Int(ceil(Double(playlist.count) / Double(playlistPageSize))), 1)
            playlistPage = min(playlistPage + 1, pageCount - 1)
        case .playlistItem(let id):
            guard let item = playlist.first(where: { $0.id == id }) else { return }
            open(item)
            hudMode = .main
        }
    }

    private func switchRelative(by offset: Int) {
        guard playlist.count > 1,
              let index = playlist.firstIndex(where: { $0.id == currentItem.id })
        else { return }
        let nextIndex = (index + offset + playlist.count) % playlist.count
        open(playlist[nextIndex])
    }

    private func open(_ item: PlaylistItem) {
        session?.shutdown()
        try? modelContext.save()
        currentItem = item
        currentItem.lastPlayedAt = .now
        setupError = nil
        do {
            session = try PlayerSession(item: item)
        } catch {
            session = nil
            setupError = error.localizedDescription
        }
    }

    private func saveItemSettings() {
        try? modelContext.save()
    }

    private func binocularStatus(title: String) -> some View {
        HStack(spacing: 0) {
            statusEye(title: title)
            statusEye(title: title)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func statusEye(title: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
            Text("Unable to play video")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Retry", systemImage: "arrow.clockwise") {
                    open(currentItem)
                }
                .buttonStyle(.bordered)

                Button("Back") {
                    closePlayer()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private func closePlayer() {
        OrientationManager.lockPortrait()
        dismiss()
    }
}
