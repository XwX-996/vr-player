import CoreVideo
import MetalKit
import QuartzCore
import UIKit
import simd

nonisolated struct VRRenderSettings: Equatable, Sendable {
    var projection: VRProjection
    var stereoLayout: StereoLayout
    var presentationMode: VRPresentationMode
    var threeDMode: VRThreeDMode
    var vrGlassesEnabled: Bool
    var displayMode: VRDisplayMode
    var distortionStrength: Int
    var edgeCorrection: Int
    var pupilDistance: Int
    var eyeDistance: Int
    var eyeAspect: Int
    var eyeScale: Int
    var brightness: Int
    var contrast: Int
    var saturation: Int

    init(preferences: VRPlayerPreferences) {
        projection = preferences.projection
        stereoLayout = preferences.stereoLayout
        presentationMode = preferences.presentationMode
        threeDMode = preferences.threeDMode
        vrGlassesEnabled = preferences.vrGlassesEnabled
        displayMode = preferences.displayMode
        distortionStrength = preferences.distortionStrength
        edgeCorrection = preferences.edgeCorrection
        pupilDistance = preferences.pupilDistance
        eyeDistance = preferences.eyeDistance
        eyeAspect = preferences.eyeAspect
        eyeScale = preferences.eyeScale
        brightness = preferences.brightness
        contrast = preferences.contrast
        saturation = preferences.saturation
    }

    var preferences: VRPlayerPreferences {
        VRPlayerPreferences(
            projection: projection,
            stereoLayout: stereoLayout,
            presentationMode: presentationMode,
            threeDMode: threeDMode,
            vrGlassesEnabled: vrGlassesEnabled,
            displayMode: displayMode,
            distortionStrength: distortionStrength,
            edgeCorrection: edgeCorrection,
            pupilDistance: pupilDistance,
            eyeDistance: eyeDistance,
            eyeAspect: eyeAspect,
            eyeScale: eyeScale,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            repeatsCurrentItem: false,
            playbackRate: 1
        )
    }

    var usesDualEyeViewports: Bool {
        switch presentationMode {
        case .flat:
            false
        case .panorama:
            vrGlassesEnabled
        case .threeD:
            true
        }
    }

    var effectiveStereoLayout: StereoLayout {
        presentationMode == .panorama ? stereoLayout : .mono
    }

    var renderPreferences: VRPlayerPreferences {
        var value = preferences
        value.vrGlassesEnabled = usesDualEyeViewports
        return value
    }
}

private struct SphereVertex {
    var position: SIMD3<Float>
    var textureCoordinate: SIMD2<Float>
}

private struct SphereUniforms {
    var modelViewProjection: simd_float4x4
    var eyeIndex: UInt32
    var stereoLayout: UInt32
}

private struct FlatVideoUniforms {
    var positionScale: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
}

private struct ColorUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var padding: Float = 0
}

private struct HUDVertex {
    var position: SIMD3<Float>
    var textureCoordinate: SIMD2<Float>
}

private struct HUDUniforms {
    var modelViewProjection: simd_float4x4
}

private struct ReticleUniforms {
    var ndcScale: SIMD2<Float>
    var progress: Float
    var active: UInt32
}

private struct DistortionUniforms {
    var k1: Float
    var k2: Float
    var horizontalInset: Float
    var verticalInset: Float
}

private final class VideoTextureResources: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let lumaReference: CVMetalTexture
    let chromaReference: CVMetalTexture
    let luma: MTLTexture
    let chroma: MTLTexture

    init(
        pixelBuffer: CVPixelBuffer,
        lumaReference: CVMetalTexture,
        chromaReference: CVMetalTexture,
        luma: MTLTexture,
        chroma: MTLTexture
    ) {
        self.pixelBuffer = pixelBuffer
        self.lumaReference = lumaReference
        self.chromaReference = chromaReference
        self.luma = luma
        self.chroma = chroma
    }
}

private enum VideoRenderInputError: LocalizedError {
    case unsupportedPixelFormat(OSType)
    case invalidPlaneCount(Int)
    case textureCreationFailed(lumaStatus: CVReturn, chromaStatus: CVReturn)

    var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat(let format):
            "解码后的视频使用了不支持的像素格式（\(MediaImportValidator.fourCCString(format))），仅支持渲染 8 位 NV12 SDR 画面。"
        case .invalidPlaneCount(let count):
            "解码后的视频包含 \(count) 个图像平面，8 位 NV12 必须包含两个平面。"
        case .textureCreationFailed(let lumaStatus, let chromaStatus):
            "Metal 无法为解码画面创建纹理（亮度 \(lumaStatus)，色度 \(chromaStatus)），画面尺寸可能超出此设备的纹理限制。"
        }
    }
}

nonisolated enum VRHUDGeometry {
    static let referencePanelWidth: Float = 3
    static let panelHeight: Float = referencePanelWidth / 1.875
    static let panelDistance: Float = 1.75
    static let horizontalSegmentCount = 64
    static let horizontalRadians = 2 * atan(referencePanelWidth / (2 * panelDistance))

    private static let intersectionEpsilon: Float = 0.0001

    static func surfacePoint(textureCoordinate: SIMD2<Float>) -> SIMD3<Float> {
        let angle = (textureCoordinate.x - 0.5) * horizontalRadians
        return SIMD3(
            panelDistance * sin(angle),
            (0.5 - textureCoordinate.y) * panelHeight,
            panelDistance * (1 - cos(angle))
        )
    }

    static func textureCoordinate(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>
    ) -> SIMD2<Float>? {
        let centeredOriginZ = rayOrigin.z - panelDistance
        let a = rayDirection.x * rayDirection.x + rayDirection.z * rayDirection.z
        guard a > intersectionEpsilon else { return nil }

        let b = 2 * (
            rayOrigin.x * rayDirection.x
                + centeredOriginZ * rayDirection.z
        )
        let c = rayOrigin.x * rayOrigin.x
            + centeredOriginZ * centeredOriginZ
            - panelDistance * panelDistance
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }

        let squareRoot = sqrt(discriminant)
        let denominator = 2 * a
        let distances = [
            (-b - squareRoot) / denominator,
            (-b + squareRoot) / denominator,
        ].sorted()

        for distance in distances where distance > intersectionEpsilon {
            let point = rayOrigin + rayDirection * distance
            let angle = atan2(point.x, panelDistance - point.z)
            let u = angle / horizontalRadians + 0.5
            let v = 0.5 - point.y / panelHeight
            guard u >= -intersectionEpsilon,
                  u <= 1 + intersectionEpsilon,
                  v >= -intersectionEpsilon,
                  v <= 1 + intersectionEpsilon
            else { continue }
            return SIMD2(
                min(max(u, 0), 1),
                min(max(v, 0), 1)
            )
        }
        return nil
    }
}

final class VRMetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    var frameProvider: (any VideoFrameProviding)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedFrameProvider
        }
        set {
            stateLock.lock()
            storedFrameProvider = newValue
            stateLock.unlock()
        }
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let spherePipeline: MTLRenderPipelineState
    private let flatVideoPipeline: MTLRenderPipelineState
    private let hudPipeline: MTLRenderPipelineState
    private let reticlePipeline: MTLRenderPipelineState
    private let fallbackDistortionPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let textureLoader: MTKTextureLoader
    private let cardboard: CardboardRuntimeBridge
    private let sphere360: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)
    private let hemisphere180: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)
    private let hudVertices: MTLBuffer
    private let hudVertexCount: Int
    private let inFlightSemaphore = DispatchSemaphore(value: 2)
    private let stateLock = NSLock()
    private var storedFrameProvider: (any VideoFrameProviding)?
    private var settings = VRRenderSettings(preferences: .default)
    private var hudState: VRHUDState?
    private var hudTexture: MTLTexture?
    private var actionHandler: (@Sendable (VRControlActivation) -> Void)?
    private var eyeTexture: MTLTexture?
    private var lastVideoFrame: VideoFrame?

    private let interactionLock = NSLock()
    private var visibilityRequest: Bool?
    private var controlsVisible = false
    private var panelModelMatrix = matrix_identity_float4x4
    private var dwellTracker = GazeDwellTracker()
    private var gestureDetector = HeadGestureDetector()
    private var manualYaw: Float = 0
    private var manualPitch: Float = 0
    private var latestTrackedHeadAngles: VRHeadAngles?
    private var contentReferenceAngles: VRHeadAngles?
    private var contentRecenterPending = false

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let sphereVertex = library.makeFunction(name: "sphereVertex"),
              let flatVideoVertex = library.makeFunction(name: "flatVideoVertex"),
              let yuvFragment = library.makeFunction(name: "yuvFragment"),
              let hudVertex = library.makeFunction(name: "hudVertex"),
              let hudFragment = library.makeFunction(name: "hudFragment"),
              let reticleVertex = library.makeFunction(name: "reticleVertex"),
              let reticleFragment = library.makeFunction(name: "reticleFragment"),
              let fullScreenVertex = library.makeFunction(name: "fullScreenVertex"),
              let distortionFragment = library.makeFunction(name: "distortionFragment"),
              let copyFragment = library.makeFunction(name: "copyFragment")
        else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        textureLoader = MTKTextureLoader(device: device)
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false

        let sphereDescriptor = MTLRenderPipelineDescriptor()
        sphereDescriptor.vertexFunction = sphereVertex
        sphereDescriptor.fragmentFunction = yuvFragment
        sphereDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let spherePipeline = try? device.makeRenderPipelineState(descriptor: sphereDescriptor) else {
            return nil
        }
        self.spherePipeline = spherePipeline

        let flatVideoDescriptor = MTLRenderPipelineDescriptor()
        flatVideoDescriptor.vertexFunction = flatVideoVertex
        flatVideoDescriptor.fragmentFunction = yuvFragment
        flatVideoDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let flatVideoPipeline = try? device.makeRenderPipelineState(descriptor: flatVideoDescriptor) else {
            return nil
        }
        self.flatVideoPipeline = flatVideoPipeline

        let hudDescriptor = MTLRenderPipelineDescriptor()
        hudDescriptor.vertexFunction = hudVertex
        hudDescriptor.fragmentFunction = hudFragment
        hudDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        Self.enableAlphaBlending(hudDescriptor.colorAttachments[0])
        guard let hudPipeline = try? device.makeRenderPipelineState(descriptor: hudDescriptor) else {
            return nil
        }
        self.hudPipeline = hudPipeline

        let reticleDescriptor = MTLRenderPipelineDescriptor()
        reticleDescriptor.vertexFunction = reticleVertex
        reticleDescriptor.fragmentFunction = reticleFragment
        reticleDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        Self.enableAlphaBlending(reticleDescriptor.colorAttachments[0])
        guard let reticlePipeline = try? device.makeRenderPipelineState(descriptor: reticleDescriptor) else {
            return nil
        }
        self.reticlePipeline = reticlePipeline

        let distortionDescriptor = MTLRenderPipelineDescriptor()
        distortionDescriptor.vertexFunction = fullScreenVertex
        distortionDescriptor.fragmentFunction = distortionFragment
        distortionDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let fallbackDistortionPipeline = try? device.makeRenderPipelineState(descriptor: distortionDescriptor) else {
            return nil
        }
        self.fallbackDistortionPipeline = fallbackDistortionPipeline

        let copyDescriptor = MTLRenderPipelineDescriptor()
        copyDescriptor.vertexFunction = fullScreenVertex
        copyDescriptor.fragmentFunction = copyFragment
        copyDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let copyPipeline = try? device.makeRenderPipelineState(descriptor: copyDescriptor) else {
            return nil
        }
        self.copyPipeline = copyPipeline

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }
        textureCache = cache

        sphere360 = Self.makeSphere(device: device, horizontalRadians: VRUVMapping.horizontalRadians(for: .sphere360))
        hemisphere180 = Self.makeSphere(device: device, horizontalRadians: VRUVMapping.horizontalRadians(for: .hemisphere180))
        let panelVertices = Self.makeHUDVertices()
        guard let hudVertices = device.makeBuffer(
            bytes: panelVertices,
            length: panelVertices.count * MemoryLayout<HUDVertex>.stride
        ) else { return nil }
        self.hudVertices = hudVertices
        hudVertexCount = panelVertices.count
        cardboard = CardboardRuntimeBridge(device: device, pixelFormat: view.colorPixelFormat)

        super.init()
        view.delegate = self
        view.preferredFramesPerSecond = 120
    }

    func update(
        settings: VRRenderSettings,
        hudState: VRHUDState,
        actionHandler: @escaping @Sendable (VRControlActivation) -> Void
    ) {
        stateLock.lock()
        let hudChanged = self.hudState != hudState
        let previousSettings = self.settings
        stateLock.unlock()

        let texture: MTLTexture?
        if hudChanged,
           let image = VRHUDTextureFactory.makeImage(state: hudState) {
            texture = try? textureLoader.newTexture(
                cgImage: image,
                options: [
                    .SRGB: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                ]
            )
        } else {
            texture = nil
        }

        let enteredThreeDFill = settings.presentationMode == .threeD
            && settings.threeDMode == .fill
            && (previousSettings.presentationMode != .threeD || previousSettings.threeDMode != .fill)
        if enteredThreeDFill {
            interactionLock.lock()
            contentRecenterPending = true
            interactionLock.unlock()
        }

        stateLock.lock()
        self.settings = settings
        self.hudState = hudState
        if let texture {
            hudTexture = texture
        }
        self.actionHandler = actionHandler
        stateLock.unlock()
    }

    func showControls() {
        interactionLock.lock()
        visibilityRequest = true
        interactionLock.unlock()
    }

    func hideControls() {
        interactionLock.lock()
        visibilityRequest = false
        interactionLock.unlock()
    }

    func recenter() {
        stateLock.lock()
        let presentationMode = settings.presentationMode
        let threeDMode = settings.threeDMode
        stateLock.unlock()

        interactionLock.lock()
        manualYaw = 0
        manualPitch = 0
        if presentationMode == .threeD, threeDMode == .fill {
            if let latestTrackedHeadAngles {
                contentReferenceAngles = latestTrackedHeadAngles
                contentRecenterPending = false
            } else {
                contentRecenterPending = true
            }
        }
        interactionLock.unlock()
        if presentationMode == .panorama {
            cardboard.recenterHeadTracking()
        }
    }

    func adjustManualLook(deltaX: Float, deltaY: Float) {
        interactionLock.lock()
        manualYaw -= deltaX * 0.004
        manualPitch = min(max(manualPitch - deltaY * 0.004, -.pi * 0.48), .pi * 0.48)
        interactionLock.unlock()
    }

    func pauseTracking() {
        cardboard.pauseHeadTracking()
    }

    func resumeTracking() {
        cardboard.resumeHeadTracking()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        eyeTexture = nil
    }

    func draw(in view: MTKView) {
        let maximumFramesPerSecond = min(
            view.window?.screen.maximumFramesPerSecond ?? view.preferredFramesPerSecond,
            120
        )
        if maximumFramesPerSecond > 0,
           view.preferredFramesPerSecond != maximumFramesPerSecond {
            view.preferredFramesPerSecond = maximumFramesPerSecond
        }

        guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer {
            if !submitted {
                inFlightSemaphore.signal()
            }
        }

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let eyeTexture = makeEyeTextureIfNeeded(size: view.drawableSize)
        else { return }

        let renderTime = CACurrentMediaTime()
        let presentationTime = VRFrameTiming.nextPresentationTime(
            now: renderTime,
            framesPerSecond: view.preferredFramesPerSecond
        )

        stateLock.lock()
        let currentFrameProvider = storedFrameProvider
        let currentSettings = settings
        let currentHUDState = hudState
        let currentHUDTexture = hudTexture
        let currentActionHandler = actionHandler
        stateLock.unlock()
        let isRecenterCountdownVisible = currentHUDState?.recenterCountdown != nil

        if let newFrame = currentFrameProvider?.copyFrame(
            forPresentationHostTime: presentationTime
        ) {
            lastVideoFrame = newFrame
        }

        cardboard.updateDistortionStrengthMultiplier(
            VRDistortionTuning.multiplier(for: currentSettings.distortionStrength),
            edgeCorrectionMultiplier: VRDistortionTuning.multiplier(for: currentSettings.edgeCorrection)
        )
        cardboard.updateDrawableWidth(eyeTexture.width, height: eyeTexture.height)
        let interfaceOrientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation
            ?? .landscapeLeft
        let deviceOrientation = VROrientationMapping.deviceOrientation(
            for: interfaceOrientation
        )
        let trackedHeadView = cardboard.headViewMatrix(
            forTimestamp: presentationTime,
            deviceOrientation: deviceOrientation
        )
        let trackedHeadAngles = VRFlatVideoLayout.headAngles(fromHeadView: trackedHeadView)
        let contentReferenceAngles = updateContentTracking(
            headAngles: trackedHeadAngles,
            settings: currentSettings
        )
        let headView = manualLookMatrix() * trackedHeadView

        applyVisibilityRequest(headView: headView)
        if isRecenterCountdownVisible {
            controlsVisible = false
            dwellTracker.reset()
            gestureDetector.reset()
        } else {
            let pitch = Self.pitch(fromHeadView: headView)
            if gestureDetector.observe(pitch: pitch, at: renderTime) {
                showControls(at: headView)
            }
        }

        let currentGazeHit: VRControlHit?
        if controlsVisible, let currentHUDState {
            currentGazeHit = gazeHit(headView: headView, state: currentHUDState)
        } else {
            currentGazeHit = nil
        }
        if let activation = dwellTracker.update(hit: currentGazeHit, at: renderTime),
           let currentActionHandler {
            DispatchQueue.main.async {
                currentActionHandler(activation)
            }
        }

        let eyePass = MTLRenderPassDescriptor()
        eyePass.colorAttachments[0].texture = eyeTexture
        eyePass.colorAttachments[0].loadAction = .clear
        eyePass.colorAttachments[0].storeAction = .store
        eyePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let eyeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: eyePass) else { return }

        let videoResources: VideoTextureResources?
        if let lastVideoFrame {
            switch makeYUVTextures(pixelBuffer: lastVideoFrame.pixelBuffer) {
            case .success(let resources):
                videoResources = resources
            case .failure(let error):
                videoResources = nil
                currentFrameProvider?.reportRenderFailure(error.localizedDescription)
            }
        } else {
            videoResources = nil
        }
        if let videoResources {
            drawVideo(
                encoder: eyeEncoder,
                eyeTexture: eyeTexture,
                textures: (videoResources.luma, videoResources.chroma),
                pixelBuffer: videoResources.pixelBuffer,
                settings: currentSettings,
                headView: headView,
                trackedHeadAngles: trackedHeadAngles,
                contentReferenceAngles: contentReferenceAngles
            )
        }
        if (controlsVisible || isRecenterCountdownVisible), let currentHUDTexture {
            let modelMatrix = isRecenterCountdownVisible
                ? simd_inverse(headView) * simd_float4x4.translation(
                    x: 0,
                    y: 0,
                    z: -VRHUDGeometry.panelDistance
                )
                : panelModelMatrix
            drawHUD(
                encoder: eyeEncoder,
                eyeTexture: eyeTexture,
                texture: currentHUDTexture,
                headView: headView,
                modelMatrix: modelMatrix,
                settings: currentSettings
            )
        }
        if controlsVisible, !isRecenterCountdownVisible {
            drawReticle(
                encoder: eyeEncoder,
                eyeTexture: eyeTexture,
                active: controlsVisible && dwellTracker.target != nil,
                progress: dwellTracker.progress,
                settings: currentSettings
            )
        }
        eyeEncoder.endEncoding()

        guard let displayPass = view.currentRenderPassDescriptor,
              let displayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: displayPass)
        else { return }
        if currentSettings.usesDualEyeViewports,
           currentSettings.displayMode == .fishEye,
           cardboard.isReady {
            cardboard.renderEyeTexture(
                eyeTexture,
                commandEncoder: displayEncoder,
                screenWidth: eyeTexture.width,
                screenHeight: eyeTexture.height
            )
        } else if currentSettings.usesDualEyeViewports,
                  currentSettings.displayMode == .fishEye {
            displayEncoder.setRenderPipelineState(fallbackDistortionPipeline)
            displayEncoder.setFragmentTexture(eyeTexture, index: 0)
            var distortion = DistortionUniforms(
                k1: VRDistortionTuning.coefficient(base: 0.12, adjustment: currentSettings.distortionStrength),
                k2: VRDistortionTuning.coefficient(base: 0.05, adjustment: currentSettings.edgeCorrection),
                horizontalInset: 0.02,
                verticalInset: 0.04
            )
            displayEncoder.setFragmentBytes(&distortion, length: MemoryLayout<DistortionUniforms>.stride, index: 0)
            displayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else {
            displayEncoder.setRenderPipelineState(copyPipeline)
            displayEncoder.setFragmentTexture(eyeTexture, index: 0)
            displayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        displayEncoder.endEncoding()

        commandBuffer.present(drawable)
        let submissionGate = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(videoResources) {}
            submissionGate.signal()
        }
        submitted = true
        commandBuffer.commit()
    }

    private func drawVideo(
        encoder: MTLRenderCommandEncoder,
        eyeTexture: MTLTexture,
        textures: (luma: MTLTexture, chroma: MTLTexture),
        pixelBuffer: CVPixelBuffer,
        settings: VRRenderSettings,
        headView: simd_float4x4,
        trackedHeadAngles: VRHeadAngles,
        contentReferenceAngles: VRHeadAngles
    ) {
        encoder.setFragmentTexture(textures.luma, index: 0)
        encoder.setFragmentTexture(textures.chroma, index: 1)
        var colorUniforms = ColorUniforms(
            brightness: Float(settings.brightness) / 200,
            contrast: 1 + Float(settings.contrast) / 100,
            saturation: 1 + Float(settings.saturation) / 100
        )
        encoder.setFragmentBytes(&colorUniforms, length: MemoryLayout<ColorUniforms>.stride, index: 0)

        if settings.presentationMode == .panorama {
            drawPanoramaVideo(
                encoder: encoder,
                eyeTexture: eyeTexture,
                settings: settings,
                headView: headView
            )
        } else {
            drawFlatVideo(
                encoder: encoder,
                eyeTexture: eyeTexture,
                pixelBuffer: pixelBuffer,
                settings: settings,
                trackedHeadAngles: trackedHeadAngles,
                contentReferenceAngles: contentReferenceAngles
            )
        }
    }

    private func drawPanoramaVideo(
        encoder: MTLRenderCommandEncoder,
        eyeTexture: MTLTexture,
        settings: VRRenderSettings,
        headView: simd_float4x4
    ) {
        encoder.setRenderPipelineState(spherePipeline)
        let mesh = settings.projection == .sphere360 ? sphere360 : hemisphere180
        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        let viewCount = settings.usesDualEyeViewports ? 2 : 1

        for eye in 0..<viewCount {
            let viewport = setViewport(encoder: encoder, eye: eye, eyeTexture: eyeTexture, settings: settings)
            var uniforms = SphereUniforms(
                modelViewProjection: eyeViewProjection(
                    eye: eye,
                    headView: headView,
                    fallbackAspect: Float(viewport.width / viewport.height),
                    settings: settings
                ),
                eyeIndex: UInt32(eye),
                stereoLayout: stereoLayoutValue(settings.effectiveStereoLayout)
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SphereUniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.count,
                indexType: .uint32,
                indexBuffer: mesh.indices,
                indexBufferOffset: 0
            )
        }
    }

    private func drawFlatVideo(
        encoder: MTLRenderCommandEncoder,
        eyeTexture: MTLTexture,
        pixelBuffer: CVPixelBuffer,
        settings: VRRenderSettings,
        trackedHeadAngles: VRHeadAngles,
        contentReferenceAngles: VRHeadAngles
    ) {
        encoder.setRenderPipelineState(flatVideoPipeline)
        let normalizedViewport = VRDisplayGeometry.viewport(
            eye: 0,
            preferences: settings.renderPreferences
        )
        let viewportSize = SIMD2<Float>(
            Float(normalizedViewport.width * Double(eyeTexture.width)),
            Float(normalizedViewport.height * Double(eyeTexture.height))
        )
        let displaySize = CVImageBufferGetDisplaySize(pixelBuffer)
        let sourceSize: SIMD2<Float>
        if displaySize.width > 0, displaySize.height > 0 {
            sourceSize = SIMD2(Float(displaySize.width), Float(displaySize.height))
        } else {
            sourceSize = SIMD2(
                Float(CVPixelBufferGetWidth(pixelBuffer)),
                Float(CVPixelBufferGetHeight(pixelBuffer))
            )
        }

        let geometry: VRFlatVideoGeometry
        if settings.presentationMode == .threeD, settings.threeDMode == .fill {
            geometry = VRFlatVideoLayout.fill(
                sourceSize: sourceSize,
                viewportSize: viewportSize,
                headAngles: trackedHeadAngles,
                referenceAngles: contentReferenceAngles,
                fieldOfView: flatVideoFieldOfView(
                    settings: settings,
                    fallbackAspect: viewportSize.x / max(viewportSize.y, 1)
                )
            )
        } else {
            geometry = VRFlatVideoLayout.fit(sourceSize: sourceSize, viewportSize: viewportSize)
        }

        var uniforms = FlatVideoUniforms(
            positionScale: geometry.positionScale,
            uvOrigin: geometry.uvOrigin,
            uvSize: geometry.uvSize
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FlatVideoUniforms>.stride, index: 0)
        let viewCount = settings.usesDualEyeViewports ? 2 : 1
        for eye in 0..<viewCount {
            setViewport(encoder: encoder, eye: eye, eyeTexture: eyeTexture, settings: settings)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func drawHUD(
        encoder: MTLRenderCommandEncoder,
        eyeTexture: MTLTexture,
        texture: MTLTexture,
        headView: simd_float4x4,
        modelMatrix: simd_float4x4,
        settings: VRRenderSettings
    ) {
        encoder.setRenderPipelineState(hudPipeline)
        encoder.setVertexBuffer(hudVertices, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        let viewCount = settings.usesDualEyeViewports ? 2 : 1

        for eye in 0..<viewCount {
            let viewport = setViewport(encoder: encoder, eye: eye, eyeTexture: eyeTexture, settings: settings)
            var uniforms = HUDUniforms(
                modelViewProjection: eyeViewProjection(
                    eye: eye,
                    headView: headView,
                    fallbackAspect: Float(viewport.width / viewport.height),
                    settings: settings
                ) * modelMatrix
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<HUDUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: hudVertexCount)
        }
    }

    private func drawReticle(
        encoder: MTLRenderCommandEncoder,
        eyeTexture: MTLTexture,
        active: Bool,
        progress: Float,
        settings: VRRenderSettings
    ) {
        encoder.setRenderPipelineState(reticlePipeline)
        let viewCount = settings.usesDualEyeViewports ? 2 : 1
        for eye in 0..<viewCount {
            let viewport = setViewport(encoder: encoder, eye: eye, eyeTexture: eyeTexture, settings: settings)
            let radiusPixels: Float = active ? 25 : 18
            var uniforms = ReticleUniforms(
                ndcScale: SIMD2(radiusPixels * 2 / Float(viewport.width), radiusPixels * 2 / Float(viewport.height)),
                progress: progress,
                active: active ? 1 : 0
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ReticleUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReticleUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func eyeViewProjection(
        eye: Int,
        headView: simd_float4x4,
        fallbackAspect: Float,
        settings: VRRenderSettings
    ) -> simd_float4x4 {
        let preferences = settings.renderPreferences
        if settings.usesDualEyeViewports, cardboard.isReady {
            let projection = adjustedCardboardProjection(eye: eye, settings: settings)
            return VRPoseMath.eyeViewProjection(
                projection: projection,
                eyeFromHead: cardboard.eyeFromHeadMatrix(forEye: eye),
                headView: headView
            )
        }
        let projection = simd_float4x4.perspective(
            verticalFieldOfView: VRDisplayGeometry.verticalFieldOfView(preferences: preferences),
            aspectRatio: fallbackAspect,
            near: 0.01,
            far: 10
        )
        let halfIPD: Float = settings.usesDualEyeViewports ? 0.032 : 0
        let eyeFromHead = simd_float4x4.translation(
            x: eye == 0 ? halfIPD : -halfIPD,
            y: 0,
            z: 0
        )
        return VRPoseMath.eyeViewProjection(
            projection: projection,
            eyeFromHead: eyeFromHead,
            headView: headView
        )
    }

    private func adjustedCardboardProjection(
        eye: Int,
        settings: VRRenderSettings
    ) -> simd_float4x4 {
        var projection = VRPoseMath.metalProjection(
            fromCardboardProjection: cardboard.projectionMatrix(forEye: eye)
        )
        let distanceAmount = Float(settings.eyeDistance) / 100
        let fieldOfViewScale = 1 - distanceAmount * 0.36
        projection.columns.0.x *= fieldOfViewScale
        projection.columns.1.y *= fieldOfViewScale
        return projection
    }

    private func flatVideoFieldOfView(
        settings: VRRenderSettings,
        fallbackAspect: Float
    ) -> VRFieldOfView {
        if settings.usesDualEyeViewports, cardboard.isReady,
           let fieldOfView = VRFieldOfView.conservative(projections: [
               adjustedCardboardProjection(eye: 0, settings: settings),
               adjustedCardboardProjection(eye: 1, settings: settings),
           ]) {
            return fieldOfView
        }
        return VRFieldOfView.symmetric(
            verticalRadians: VRDisplayGeometry.verticalFieldOfView(preferences: settings.renderPreferences),
            aspectRatio: fallbackAspect
        )
    }

    private func gazeHit(headView: simd_float4x4, state: VRHUDState) -> VRControlHit? {
        let panelFromHead = simd_inverse(panelModelMatrix) * simd_inverse(headView)
        let origin4 = panelFromHead * SIMD4<Float>(0, 0, 0, 1)
        let forward4 = panelFromHead * SIMD4<Float>(0, 0, -1, 1)
        let direction = SIMD3<Float>(forward4.x - origin4.x, forward4.y - origin4.y, forward4.z - origin4.z)
        guard let textureCoordinate = VRHUDGeometry.textureCoordinate(
            rayOrigin: SIMD3(origin4.x, origin4.y, origin4.z),
            rayDirection: direction
        ) else { return nil }
        return VRHUDLayout.hitTest(state: state, point: textureCoordinate)
    }

    private func applyVisibilityRequest(headView: simd_float4x4) {
        interactionLock.lock()
        let request = visibilityRequest
        visibilityRequest = nil
        interactionLock.unlock()
        guard let request else { return }
        if request {
            showControls(at: headView)
        } else {
            controlsVisible = false
            dwellTracker.reset()
            gestureDetector.reset()
        }
    }

    private func showControls(at headView: simd_float4x4) {
        controlsVisible = true
        panelModelMatrix = simd_inverse(headView) * simd_float4x4.translation(
            x: 0,
            y: 0,
            z: -VRHUDGeometry.panelDistance
        )
        dwellTracker.reset()
    }

    private func makeEyeTextureIfNeeded(size: CGSize) -> MTLTexture? {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        if eyeTexture?.width == width, eyeTexture?.height == height {
            return eyeTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        eyeTexture = device.makeTexture(descriptor: descriptor)
        return eyeTexture
    }

    private func makeYUVTextures(
        pixelBuffer: CVPixelBuffer
    ) -> Result<VideoTextureResources, VideoRenderInputError> {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return .failure(.unsupportedPixelFormat(pixelFormat))
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            return .failure(.invalidPlaneCount(CVPixelBufferGetPlaneCount(pixelBuffer)))
        }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        var lumaReference: CVMetalTexture?
        var chromaReference: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            lumaWidth,
            lumaHeight,
            0,
            &lumaReference
        )
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            chromaWidth,
            chromaHeight,
            1,
            &chromaReference
        )
        guard lumaStatus == kCVReturnSuccess,
              chromaStatus == kCVReturnSuccess,
              let lumaReference,
              let chromaReference,
              let luma = CVMetalTextureGetTexture(lumaReference),
              let chroma = CVMetalTextureGetTexture(chromaReference)
        else {
            return .failure(.textureCreationFailed(lumaStatus: lumaStatus, chromaStatus: chromaStatus))
        }
        return .success(VideoTextureResources(
            pixelBuffer: pixelBuffer,
            lumaReference: lumaReference,
            chromaReference: chromaReference,
            luma: luma,
            chroma: chroma
        ))
    }

    @discardableResult
    private func setViewport(
        encoder: MTLRenderCommandEncoder,
        eye: Int,
        eyeTexture: MTLTexture,
        settings: VRRenderSettings
    ) -> MTLViewport {
        let normalized = VRDisplayGeometry.viewport(eye: eye, preferences: settings.renderPreferences)
        let viewport = MTLViewport(
            originX: normalized.x * Double(eyeTexture.width),
            originY: normalized.y * Double(eyeTexture.height),
            width: normalized.width * Double(eyeTexture.width),
            height: normalized.height * Double(eyeTexture.height),
            znear: 0,
            zfar: 1
        )
        encoder.setViewport(viewport)
        if settings.usesDualEyeViewports {
            let halfWidth = eyeTexture.width / 2
            let safeEye = min(max(eye, 0), 1)
            encoder.setScissorRect(
                MTLScissorRect(
                    x: safeEye == 0 ? 0 : halfWidth,
                    y: 0,
                    width: safeEye == 0 ? halfWidth : eyeTexture.width - halfWidth,
                    height: eyeTexture.height
                )
            )
        } else {
            encoder.setScissorRect(
                MTLScissorRect(x: 0, y: 0, width: eyeTexture.width, height: eyeTexture.height)
            )
        }
        return viewport
    }

    private func stereoLayoutValue(_ layout: StereoLayout) -> UInt32 {
        switch layout {
        case .mono: 0
        case .sideBySide: 1
        case .topBottom: 2
        }
    }

    private func manualLookMatrix() -> simd_float4x4 {
        interactionLock.lock()
        let yaw = manualYaw
        let pitch = manualPitch
        interactionLock.unlock()
        return simd_float4x4.rotationX(pitch) * simd_float4x4.rotationY(yaw)
    }

    private func updateContentTracking(
        headAngles: VRHeadAngles,
        settings: VRRenderSettings
    ) -> VRHeadAngles {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        latestTrackedHeadAngles = headAngles
        if settings.presentationMode == .threeD, settings.threeDMode == .fill {
            if contentRecenterPending || contentReferenceAngles == nil {
                contentReferenceAngles = headAngles
                contentRecenterPending = false
            }
            return contentReferenceAngles ?? headAngles
        }
        return contentReferenceAngles ?? headAngles
    }

    private static func pitch(fromHeadView headView: simd_float4x4) -> Float {
        let worldFromHead = simd_inverse(headView)
        let forward = worldFromHead * SIMD4<Float>(0, 0, -1, 0)
        let length = max(simd_length(SIMD3(forward.x, forward.y, forward.z)), 0.0001)
        return asin(min(max(forward.y / length, -1), 1))
    }

    private static func enableAlphaBlending(_ attachment: MTLRenderPipelineColorAttachmentDescriptor?) {
        attachment?.isBlendingEnabled = true
        attachment?.sourceRGBBlendFactor = .sourceAlpha
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    private static func makeHUDVertices() -> [HUDVertex] {
        var vertices: [HUDVertex] = []
        vertices.reserveCapacity(VRHUDGeometry.horizontalSegmentCount * 6)

        for segment in 0..<VRHUDGeometry.horizontalSegmentCount {
            let leftU = Float(segment) / Float(VRHUDGeometry.horizontalSegmentCount)
            let rightU = Float(segment + 1) / Float(VRHUDGeometry.horizontalSegmentCount)
            let topLeftUV = SIMD2<Float>(leftU, 0)
            let topRightUV = SIMD2<Float>(rightU, 0)
            let bottomLeftUV = SIMD2<Float>(leftU, 1)
            let bottomRightUV = SIMD2<Float>(rightU, 1)

            vertices.append(HUDVertex(
                position: VRHUDGeometry.surfacePoint(textureCoordinate: topLeftUV),
                textureCoordinate: topLeftUV
            ))
            vertices.append(HUDVertex(
                position: VRHUDGeometry.surfacePoint(textureCoordinate: topRightUV),
                textureCoordinate: topRightUV
            ))
            vertices.append(HUDVertex(
                position: VRHUDGeometry.surfacePoint(textureCoordinate: bottomLeftUV),
                textureCoordinate: bottomLeftUV
            ))
            vertices.append(HUDVertex(
                position: VRHUDGeometry.surfacePoint(textureCoordinate: bottomLeftUV),
                textureCoordinate: bottomLeftUV
            ))
            vertices.append(HUDVertex(
                position: VRHUDGeometry.surfacePoint(textureCoordinate: topRightUV),
                textureCoordinate: topRightUV
            ))
            vertices.append(HUDVertex(
                position: VRHUDGeometry.surfacePoint(textureCoordinate: bottomRightUV),
                textureCoordinate: bottomRightUV
            ))
        }
        return vertices
    }

    private static func makeSphere(
        device: MTLDevice,
        horizontalRadians: Float
    ) -> (vertices: MTLBuffer, indices: MTLBuffer, count: Int) {
        let horizontalSegments = 160
        let verticalSegments = 80
        var vertices: [SphereVertex] = []
        var indices: [UInt32] = []

        for y in 0...verticalSegments {
            let v = Float(y) / Float(verticalSegments)
            let latitude = (v - 0.5) * .pi
            let cosLatitude = cos(latitude)
            for x in 0...horizontalSegments {
                let u = Float(x) / Float(horizontalSegments)
                let longitude = (u - 0.5) * horizontalRadians
                vertices.append(
                    SphereVertex(
                        position: SIMD3<Float>(
                            sin(longitude) * cosLatitude,
                            sin(latitude),
                            -cos(longitude) * cosLatitude
                        ),
                        textureCoordinate: SIMD2<Float>(u, 1 - v)
                    )
                )
            }
        }

        let rowLength = horizontalSegments + 1
        for y in 0..<verticalSegments {
            for x in 0..<horizontalSegments {
                let topLeft = UInt32(y * rowLength + x)
                let bottomLeft = UInt32((y + 1) * rowLength + x)
                indices.append(contentsOf: [
                    topLeft,
                    bottomLeft,
                    topLeft + 1,
                    topLeft + 1,
                    bottomLeft,
                    bottomLeft + 1,
                ])
            }
        }

        let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<SphereVertex>.stride * vertices.count
        )!
        let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: MemoryLayout<UInt32>.stride * indices.count
        )!
        return (vertexBuffer, indexBuffer, indices.count)
    }

}
