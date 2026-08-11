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
            settings: VRRenderSettings(projection: .sphere360, stereoLayout: .mono),
            hudState: VRHUDState(
                mode: .main,
                isPlaying: true,
                position: 121,
                duration: 304,
                bufferedFraction: 0.62,
                projection: .sphere360,
                stereoLayout: .mono,
                brightness: 0.58,
                volume: 0.72,
                playlistEntries: [],
                playlistPage: 0,
                playlistPageCount: 1
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
}
#endif
