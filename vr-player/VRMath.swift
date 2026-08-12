import simd
import UIKit

nonisolated enum VRPoseMath {
    static func metalProjection(fromCardboardProjection projection: simd_float4x4) -> simd_float4x4 {
        let openGLToMetalDepth = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 0.5, 0),
            SIMD4<Float>(0, 0, 0.5, 1)
        )
        return openGLToMetalDepth * projection
    }

    static func eyeViewProjection(
        projection: simd_float4x4,
        eyeFromHead: simd_float4x4,
        headView: simd_float4x4
    ) -> simd_float4x4 {
        projection * eyeFromHead * headView
    }
}

nonisolated enum VRFrameTiming {
    static func nextPresentationTime(
        now: TimeInterval,
        framesPerSecond: Int
    ) -> TimeInterval {
        now + 1.0 / Double(max(framesPerSecond, 1))
    }
}

nonisolated enum VROrientationMapping {
    static func deviceOrientation(for interfaceOrientation: UIInterfaceOrientation) -> UIDeviceOrientation {
        switch interfaceOrientation {
        case .portrait:
            .portrait
        case .portraitUpsideDown:
            .portraitUpsideDown
        case .landscapeLeft:
            .landscapeRight
        case .landscapeRight:
            .landscapeLeft
        case .unknown:
            .landscapeLeft
        @unknown default:
            .landscapeLeft
        }
    }
}

extension simd_float4x4 {
    static func perspective(
        verticalFieldOfView: Float,
        aspectRatio: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let yScale = 1 / tan(verticalFieldOfView * 0.5)
        let xScale = yScale / aspectRatio
        let zRange = near - far
        return simd_float4x4(
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, far / zRange, -1),
            SIMD4<Float>(0, 0, (near * far) / zRange, 0)
        )
    }

    static func translation(x: Float, y: Float, z: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(x, y, z, 1)
        )
    }

    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, cosine, sine, 0),
            SIMD4<Float>(0, -sine, cosine, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(cosine, 0, -sine, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sine, 0, cosine, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}
