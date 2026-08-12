#if DEBUG
import SwiftUI

struct VRHUDPreviewScreen: View {
    @State private var frameProvider: VideoFrameProvider

    init() {
        _frameProvider = State(
            initialValue: VideoFrameProvider(output: VideoOutputFactory.makeVideoOutput())
        )
    }

    var body: some View {
        VRMetalSurface(
            frameProvider: frameProvider,
            settings: VRRenderSettings(preferences: previewPreferences),
            hudState: VRHUDState(
                mode: .main,
                isPlaying: true,
                position: 121,
                duration: 304,
                bufferedFraction: 0.62,
                projection: .sphere360,
                stereoLayout: .mono,
                presentationMode: previewPreferences.presentationMode,
                threeDMode: previewPreferences.threeDMode,
                brightness: 0.58,
                volume: 0.72,
                playlistEntries: [],
                playlistPage: 0,
                playlistPageCount: 1,
                recenterCountdown: ProcessInfo.processInfo.arguments.contains("--recenter-countdown-preview") ? 3 : nil
            ),
            actionHandler: { _ in }
        ) { renderer in
            DispatchQueue.main.async {
                renderer.showControls()
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            OrientationManager.lockLandscape()
        }
    }

    private var previewPreferences: VRPlayerPreferences {
        var preferences = VRPlayerPreferences.default
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--hud-3d-fill-preview") {
            preferences.presentationMode = .threeD
            preferences.threeDMode = .fill
        } else if arguments.contains("--hud-3d-preview") {
            preferences.presentationMode = .threeD
            preferences.threeDMode = .fit
        }
        return preferences
    }
}
#endif
