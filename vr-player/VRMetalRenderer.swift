import CoreVideo
import MetalKit
import QuartzCore
import UIKit
import simd

struct VRRenderSettings: Equatable, Sendable {
    var projection: VRProjection
    var stereoLayout: StereoLayout
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

private enum VRHUDGeometry {
    static let panelWidth: Float = 3
    static let panelHeight: Float = panelWidth / 1.875
    static let panelDistance: Float = 1.55
}

final class VRMetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    var frameProvider: VideoFrameProvider? {
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
    private let hudPipeline: MTLRenderPipelineState
    private let reticlePipeline: MTLRenderPipelineState
    private let fallbackDistortionPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let textureLoader: MTKTextureLoader
    private let cardboard: CardboardRuntimeBridge
    private let sphere360: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)
    private let hemisphere180: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)
    private let hudVertices: MTLBuffer
    private let inFlightSemaphore = DispatchSemaphore(value: 2)
    private let stateLock = NSLock()
    private var storedFrameProvider: VideoFrameProvider?
    private var settings = VRRenderSettings(projection: .sphere360, stereoLayout: .mono)
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

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let sphereVertex = library.makeFunction(name: "sphereVertex"),
              let yuvFragment = library.makeFunction(name: "yuvFragment"),
              let hudVertex = library.makeFunction(name: "hudVertex"),
              let hudFragment = library.makeFunction(name: "hudFragment"),
              let reticleVertex = library.makeFunction(name: "reticleVertex"),
              let reticleFragment = library.makeFunction(name: "reticleFragment"),
              let fullScreenVertex = library.makeFunction(name: "fullScreenVertex"),
              let distortionFragment = library.makeFunction(name: "distortionFragment")
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

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }
        textureCache = cache

        sphere360 = Self.makeSphere(device: device, horizontalRadians: VRUVMapping.horizontalRadians(for: .sphere360))
        hemisphere180 = Self.makeSphere(device: device, horizontalRadians: VRUVMapping.horizontalRadians(for: .hemisphere180))
        let panelWidth = VRHUDGeometry.panelWidth
        let panelHeight = VRHUDGeometry.panelHeight
        let panelVertices: [HUDVertex] = [
            HUDVertex(position: SIMD3(-panelWidth / 2, panelHeight / 2, 0), textureCoordinate: SIMD2(0, 0)),
            HUDVertex(position: SIMD3(panelWidth / 2, panelHeight / 2, 0), textureCoordinate: SIMD2(1, 0)),
            HUDVertex(position: SIMD3(-panelWidth / 2, -panelHeight / 2, 0), textureCoordinate: SIMD2(0, 1)),
            HUDVertex(position: SIMD3(-panelWidth / 2, -panelHeight / 2, 0), textureCoordinate: SIMD2(0, 1)),
            HUDVertex(position: SIMD3(panelWidth / 2, panelHeight / 2, 0), textureCoordinate: SIMD2(1, 0)),
            HUDVertex(position: SIMD3(panelWidth / 2, -panelHeight / 2, 0), textureCoordinate: SIMD2(1, 1)),
        ]
        guard let hudVertices = device.makeBuffer(
            bytes: panelVertices,
            length: panelVertices.count * MemoryLayout<HUDVertex>.stride
        ) else { return nil }
        self.hudVertices = hudVertices
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
        cardboard.recenterHeadTracking()
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

        if let newFrame = currentFrameProvider?.copyFrame(
            forPresentationHostTime: presentationTime
        ) {
            lastVideoFrame = newFrame
        }

        cardboard.updateDrawableWidth(eyeTexture.width, height: eyeTexture.height)
        let interfaceOrientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation
            ?? .landscapeLeft
        let deviceOrientation = VROrientationMapping.deviceOrientation(
            for: interfaceOrientation
        )
        let headView = cardboard.headViewMatrix(
            forTimestamp: presentationTime,
            deviceOrientation: deviceOrientation
        )

        applyVisibilityRequest(headView: headView)
        let pitch = Self.pitch(fromHeadView: headView)
        if gestureDetector.observe(pitch: pitch, at: renderTime) {
            showControls(at: headView)
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

        let videoResources = lastVideoFrame.flatMap {
            makeYUVTextures(pixelBuffer: $0.pixelBuffer)
        }
        if let videoResources {
            drawVideo(
                encoder: eyeEncoder,
                eyeTexture: eyeTexture,
                textures: (videoResources.luma, videoResources.chroma),
                settings: currentSettings,
                headView: headView
            )
        }
        if controlsVisible, let currentHUDTexture {
            drawHUD(
                encoder: eyeEncoder,
                eyeTexture: eyeTexture,
                texture: currentHUDTexture,
                headView: headView
            )
        }
        drawReticle(
            encoder: eyeEncoder,
            eyeTexture: eyeTexture,
            active: controlsVisible && dwellTracker.target != nil,
            progress: dwellTracker.progress
        )
        eyeEncoder.endEncoding()

        guard let displayPass = view.currentRenderPassDescriptor,
              let displayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: displayPass)
        else { return }
        if cardboard.isReady {
            cardboard.renderEyeTexture(
                eyeTexture,
                commandEncoder: displayEncoder,
                screenWidth: eyeTexture.width,
                screenHeight: eyeTexture.height
            )
        } else {
            displayEncoder.setRenderPipelineState(fallbackDistortionPipeline)
            displayEncoder.setFragmentTexture(eyeTexture, index: 0)
            var distortion = DistortionUniforms(k1: 0.12, k2: 0.05, horizontalInset: 0.02, verticalInset: 0.04)
            displayEncoder.setFragmentBytes(&distortion, length: MemoryLayout<DistortionUniforms>.stride, index: 0)
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
        settings: VRRenderSettings,
        headView: simd_float4x4
    ) {
        encoder.setRenderPipelineState(spherePipeline)
        encoder.setFragmentTexture(textures.luma, index: 0)
        encoder.setFragmentTexture(textures.chroma, index: 1)
        let mesh = settings.projection == .sphere360 ? sphere360 : hemisphere180
        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        let eyeWidth = Double(eyeTexture.width) / 2
        let height = Double(eyeTexture.height)

        for eye in 0..<2 {
            setViewport(encoder: encoder, eye: eye, eyeWidth: eyeWidth, height: height)
            var uniforms = SphereUniforms(
                modelViewProjection: eyeViewProjection(eye: eye, headView: headView, fallbackAspect: Float(eyeWidth / height)),
                eyeIndex: UInt32(eye),
                stereoLayout: settings.stereoLayout == .sideBySide ? 1 : 0
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

    private func drawHUD(
        encoder: MTLRenderCommandEncoder,
        eyeTexture: MTLTexture,
        texture: MTLTexture,
        headView: simd_float4x4
    ) {
        encoder.setRenderPipelineState(hudPipeline)
        encoder.setVertexBuffer(hudVertices, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        let eyeWidth = Double(eyeTexture.width) / 2
        let height = Double(eyeTexture.height)

        for eye in 0..<2 {
            setViewport(encoder: encoder, eye: eye, eyeWidth: eyeWidth, height: height)
            var uniforms = HUDUniforms(
                modelViewProjection: eyeViewProjection(eye: eye, headView: headView, fallbackAspect: Float(eyeWidth / height)) * panelModelMatrix
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<HUDUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func drawReticle(
        encoder: MTLRenderCommandEncoder,
        eyeTexture: MTLTexture,
        active: Bool,
        progress: Float
    ) {
        encoder.setRenderPipelineState(reticlePipeline)
        let eyeWidth = Double(eyeTexture.width) / 2
        let height = Double(eyeTexture.height)
        for eye in 0..<2 {
            setViewport(encoder: encoder, eye: eye, eyeWidth: eyeWidth, height: height)
            let radiusPixels: Float = active ? 25 : 18
            var uniforms = ReticleUniforms(
                ndcScale: SIMD2(radiusPixels * 2 / Float(eyeWidth), radiusPixels * 2 / Float(height)),
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
        fallbackAspect: Float
    ) -> simd_float4x4 {
        if cardboard.isReady {
            let projection = VRPoseMath.metalProjection(
                fromCardboardProjection: cardboard.projectionMatrix(forEye: eye)
            )
            return VRPoseMath.eyeViewProjection(
                projection: projection,
                eyeFromHead: cardboard.eyeFromHeadMatrix(forEye: eye),
                headView: headView
            )
        }
        let projection = simd_float4x4.perspective(
            verticalFieldOfView: .pi / 2,
            aspectRatio: fallbackAspect,
            near: 0.01,
            far: 10
        )
        let fallbackIPD: Float = 0.064
        let eyeFromHead = simd_float4x4.translation(
            x: eye == 0 ? fallbackIPD * 0.5 : -fallbackIPD * 0.5,
            y: 0,
            z: 0
        )
        return VRPoseMath.eyeViewProjection(
            projection: projection,
            eyeFromHead: eyeFromHead,
            headView: headView
        )
    }

    private func gazeHit(headView: simd_float4x4, state: VRHUDState) -> VRControlHit? {
        let panelFromHead = simd_inverse(panelModelMatrix) * simd_inverse(headView)
        let origin4 = panelFromHead * SIMD4<Float>(0, 0, 0, 1)
        let forward4 = panelFromHead * SIMD4<Float>(0, 0, -1, 1)
        let direction = SIMD3<Float>(forward4.x - origin4.x, forward4.y - origin4.y, forward4.z - origin4.z)
        guard abs(direction.z) > 0.0001 else { return nil }
        let distance = -origin4.z / direction.z
        guard distance > 0 else { return nil }
        let point = SIMD2<Float>(
            origin4.x + direction.x * distance,
            origin4.y + direction.y * distance
        )
        let panelWidth = VRHUDGeometry.panelWidth
        let panelHeight = VRHUDGeometry.panelHeight
        let normalized = SIMD2<Float>(point.x / panelWidth + 0.5, 0.5 - point.y / panelHeight)
        return VRHUDLayout.hitTest(state: state, point: normalized)
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

    private func makeYUVTextures(pixelBuffer: CVPixelBuffer) -> VideoTextureResources? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return nil }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        var lumaReference: CVMetalTexture?
        var chromaReference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            lumaWidth,
            lumaHeight,
            0,
            &lumaReference
        ) == kCVReturnSuccess,
        CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            chromaWidth,
            chromaHeight,
            1,
            &chromaReference
        ) == kCVReturnSuccess,
        let lumaReference,
        let chromaReference,
        let luma = CVMetalTextureGetTexture(lumaReference),
        let chroma = CVMetalTextureGetTexture(chromaReference)
        else { return nil }
        return VideoTextureResources(
            pixelBuffer: pixelBuffer,
            lumaReference: lumaReference,
            chromaReference: chromaReference,
            luma: luma,
            chroma: chroma
        )
    }

    private func setViewport(
        encoder: MTLRenderCommandEncoder,
        eye: Int,
        eyeWidth: Double,
        height: Double
    ) {
        encoder.setViewport(
            MTLViewport(
                originX: Double(eye) * eyeWidth,
                originY: 0,
                width: eyeWidth,
                height: height,
                znear: 0,
                zfar: 1
            )
        )
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
