import SwiftData
import SwiftUI
import UIKit

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(VRPlayerPreferences.storageKey) private var preferencesData = VRPlayerPreferences.default.encoded()

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
    @State private var manualControlsVisible = false
    @State private var manualControlPanel: ManualControlPanel?
    @State private var manualControlsActivityID = UUID()
    @State private var dragTranslation = CGSize.zero

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
                    settings: renderSettings,
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
                .gesture(videoGesture)

                if session.phase == .preparing || session.phase == .buffering {
                    playbackStatus(title: session.phase.title)
                }
                if case .failed(let message) = session.phase {
                    errorOverlay(message: message)
                }
            } else if let setupError {
                errorOverlay(message: setupError)
            } else {
                playbackStatus(title: "正在准备")
            }

            SystemVolumeHostView(controller: volumeController)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)

            ScreenBrightnessHostView(controller: brightnessController)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)

            if manualControlsVisible, let session {
                ManualControlsOverlay(
                    title: currentItem.name,
                    isPlaying: session.isPlaying,
                    position: session.position,
                    duration: session.duration,
                    playlist: playlist,
                    currentItemID: currentItem.id,
                    preferences: preferencesBinding,
                    panel: $manualControlPanel,
                    onClose: closePlayer,
                    onDismiss: hideManualControls,
                    onActivity: registerManualActivity,
                    onRecenter: requestRecenter,
                    onPrevious: { switchRelative(by: -1) },
                    onPlayPause: session.togglePlayback,
                    onNext: { switchRelative(by: 1) },
                    onSeek: session.seek,
                    onSelectItem: { item in
                        open(item)
                        manualControlPanel = nil
                    }
                )
                .transition(.opacity)
            }
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
        .task(id: manualControlsActivityID) {
            guard manualControlsVisible else { return }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            hideManualControls()
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
                hideManualControls()
                recenterRequestID = nil
                renderer?.pauseTracking()
                try? modelContext.save()
            }
        }
        .onChange(of: preferencesData) { _, data in
            let preferences = VRPlayerPreferences.decode(data)
            session?.setRepeatsCurrentItem(preferences.repeatsCurrentItem)
            session?.setPlaybackRate(preferences.playbackRate)
        }
    }

    private func makeHUDState(session: PlayerSession) -> VRHUDState {
        let preferences = storedPreferences
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
            projection: preferences.projection,
            stereoLayout: preferences.stereoLayout,
            presentationMode: preferences.presentationMode,
            threeDMode: preferences.threeDMode,
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
            requestRecenter()
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
            updatePreferences {
                $0.presentationMode = .panorama
                $0.projection = .hemisphere180
            }
        case .projection360:
            updatePreferences {
                $0.presentationMode = .panorama
                $0.projection = .sphere360
            }
        case .threeDFit:
            updatePreferences {
                $0.presentationMode = .threeD
                $0.threeDMode = .fit
            }
        case .threeDFill:
            updatePreferences {
                $0.presentationMode = .threeD
                $0.threeDMode = .fill
            }
        case .mono:
            guard storedPreferences.presentationMode != .threeD else { return }
            updatePreferences { $0.stereoLayout = .mono }
        case .sideBySide:
            guard storedPreferences.presentationMode != .threeD else { return }
            updatePreferences { $0.stereoLayout = .sideBySide }
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
            let preferences = storedPreferences
            session = try PlayerSession(
                item: item,
                repeatsCurrentItem: preferences.repeatsCurrentItem,
                playbackRate: preferences.playbackRate
            )
        } catch {
            session = nil
            setupError = error.localizedDescription
        }
    }

    private var storedPreferences: VRPlayerPreferences {
        VRPlayerPreferences.decode(preferencesData)
    }

    private var preferencesBinding: Binding<VRPlayerPreferences> {
        Binding(
            get: { storedPreferences },
            set: { preferencesData = $0.encoded() }
        )
    }

    private var renderSettings: VRRenderSettings {
        VRRenderSettings(preferences: storedPreferences)
    }

    private var videoGesture: some Gesture {
        TapGesture()
            .onEnded {
                guard canUseManualControls else { return }
                showManualControls()
            }
            .exclusively(before: DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard canAdjustManualLook else { return }
                    let delta = CGSize(
                        width: value.translation.width - dragTranslation.width,
                        height: value.translation.height - dragTranslation.height
                    )
                    dragTranslation = value.translation
                    renderer?.adjustManualLook(
                        deltaX: Float(delta.width),
                        deltaY: Float(delta.height)
                    )
                }
                .onEnded { _ in
                    dragTranslation = .zero
                }
            )
    }

    private var canUseManualControls: Bool {
        !manualControlsVisible
            && !renderSettings.usesDualEyeViewports
            && recenterCountdown == nil
    }

    private var canAdjustManualLook: Bool {
        canUseManualControls && storedPreferences.presentationMode == .panorama
    }

    private func updatePreferences(_ update: (inout VRPlayerPreferences) -> Void) {
        var preferences = storedPreferences
        update(&preferences)
        preferences.normalize()
        preferencesData = preferences.encoded()
    }

    private func showManualControls() {
        renderer?.hideControls()
        manualControlPanel = nil
        manualControlsVisible = true
        registerManualActivity()
    }

    private func hideManualControls() {
        withAnimation(.easeOut(duration: 0.16)) {
            manualControlsVisible = false
            manualControlPanel = nil
        }
    }

    private func registerManualActivity() {
        manualControlsActivityID = UUID()
    }

    private func requestRecenter() {
        renderer?.hideControls()
        hideManualControls()
        recenterCountdown = recenterCountdownStart
        recenterRequestID = UUID()
    }

    @ViewBuilder
    private func playbackStatus(title: String) -> some View {
        if storedPreferences.vrGlassesEnabled {
            HStack(spacing: 0) {
                statusEye(title: title)
                statusEye(title: title)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        } else {
            statusEye(title: title)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
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
            Text("无法播放视频")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("重试", systemImage: "arrow.clockwise") {
                    open(currentItem)
                }
                .buttonStyle(.bordered)

                Button("返回") {
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
