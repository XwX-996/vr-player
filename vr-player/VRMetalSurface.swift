import MetalKit
import SwiftUI

struct VRMetalSurface: UIViewRepresentable {
    let frameProvider: any VideoFrameProviding
    let settings: VRRenderSettings
    let hudState: VRHUDState
    let actionHandler: @Sendable (VRControlActivation) -> Void
    var rendererAvailable: (VRMetalRenderer) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.backgroundColor = .black
        view.isOpaque = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        if let renderer = VRMetalRenderer(view: view) {
            renderer.frameProvider = frameProvider
            renderer.update(settings: settings, hudState: hudState, actionHandler: actionHandler)
            context.coordinator.renderer = renderer
            rendererAvailable(renderer)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.frameProvider = frameProvider
        context.coordinator.renderer?.update(
            settings: settings,
            hudState: hudState,
            actionHandler: actionHandler
        )
    }

    final class Coordinator {
        var renderer: VRMetalRenderer?
    }
}
