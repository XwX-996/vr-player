import simd

nonisolated struct VRHeadAngles: Equatable, Sendable {
    var yaw: Float
    var pitch: Float

    static let zero = VRHeadAngles(yaw: 0, pitch: 0)
}

nonisolated struct VRFieldOfView: Equatable, Sendable {
    var horizontalHalfAngle: Float
    var verticalHalfAngle: Float

    static func symmetric(verticalRadians: Float, aspectRatio: Float) -> VRFieldOfView {
        let verticalHalfAngle = max(verticalRadians * 0.5, 0.0001)
        let horizontalHalfAngle = atan(tan(verticalHalfAngle) * max(aspectRatio, 0.0001))
        return VRFieldOfView(
            horizontalHalfAngle: horizontalHalfAngle,
            verticalHalfAngle: verticalHalfAngle
        )
    }

    static func conservative(projections: [simd_float4x4]) -> VRFieldOfView? {
        let halfAngles = projections.compactMap(projectionHalfAngles)
        guard !halfAngles.isEmpty else { return nil }
        return VRFieldOfView(
            horizontalHalfAngle: halfAngles.map(\.horizontal).min() ?? 0,
            verticalHalfAngle: halfAngles.map(\.vertical).min() ?? 0
        )
    }

    private static func projectionHalfAngles(
        _ projection: simd_float4x4
    ) -> (horizontal: Float, vertical: Float)? {
        let xScale = abs(projection.columns.0.x)
        let yScale = abs(projection.columns.1.y)
        guard xScale > 0.0001, yScale > 0.0001 else { return nil }

        let xOffset = projection.columns.2.x
        let yOffset = projection.columns.2.y
        let left = atan(max((1 - xOffset) / xScale, 0.0001))
        let right = atan(max((1 + xOffset) / xScale, 0.0001))
        let down = atan(max((1 - yOffset) / yScale, 0.0001))
        let up = atan(max((1 + yOffset) / yScale, 0.0001))
        return (min(left, right), min(down, up))
    }
}

nonisolated struct VRFlatVideoGeometry: Equatable, Sendable {
    var positionScale: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>

    static let fullFrame = VRFlatVideoGeometry(
        positionScale: SIMD2(1, 1),
        uvOrigin: SIMD2(0, 0),
        uvSize: SIMD2(1, 1)
    )
}

nonisolated enum VRFlatVideoLayout {
    private static let epsilon: Float = 0.0001

    static func fit(
        sourceSize: SIMD2<Float>,
        viewportSize: SIMD2<Float>
    ) -> VRFlatVideoGeometry {
        let sourceAspect = safeAspect(size: sourceSize)
        let viewportAspect = safeAspect(size: viewportSize)
        let scale: SIMD2<Float>
        if sourceAspect > viewportAspect + epsilon {
            scale = SIMD2(1, viewportAspect / sourceAspect)
        } else if sourceAspect < viewportAspect - epsilon {
            scale = SIMD2(sourceAspect / viewportAspect, 1)
        } else {
            scale = SIMD2(1, 1)
        }
        return VRFlatVideoGeometry(
            positionScale: scale,
            uvOrigin: SIMD2(0, 0),
            uvSize: SIMD2(1, 1)
        )
    }

    static func fill(
        sourceSize: SIMD2<Float>,
        viewportSize: SIMD2<Float>,
        headAngles: VRHeadAngles,
        referenceAngles: VRHeadAngles,
        fieldOfView: VRFieldOfView
    ) -> VRFlatVideoGeometry {
        let sourceAspect = safeAspect(size: sourceSize)
        let viewportAspect = safeAspect(size: viewportSize)
        let relative = relativeAngles(headAngles, reference: referenceAngles)

        if sourceAspect > viewportAspect + epsilon {
            let uSize = clamped(viewportAspect / sourceAspect, lower: epsilon, upper: 1)
            let overflow = 1 - uSize
            let contentHalfAngle = atan(sourceAspect * tan(fieldOfView.verticalHalfAngle))
            let maximumYaw = max(contentHalfAngle - fieldOfView.horizontalHalfAngle, 0)
            let progress = normalized(relative.yaw, maximum: maximumYaw)
            return VRFlatVideoGeometry(
                positionScale: SIMD2(1, 1),
                uvOrigin: SIMD2(overflow * 0.5 * (1 + progress), 0),
                uvSize: SIMD2(uSize, 1)
            )
        }

        if sourceAspect < viewportAspect - epsilon {
            let vSize = clamped(sourceAspect / viewportAspect, lower: epsilon, upper: 1)
            let overflow = 1 - vSize
            let contentHalfAngle = atan(tan(fieldOfView.horizontalHalfAngle) / sourceAspect)
            let maximumPitch = max(contentHalfAngle - fieldOfView.verticalHalfAngle, 0)
            let progress = normalized(relative.pitch, maximum: maximumPitch)
            return VRFlatVideoGeometry(
                positionScale: SIMD2(1, 1),
                uvOrigin: SIMD2(0, overflow * 0.5 * (1 - progress)),
                uvSize: SIMD2(1, vSize)
            )
        }

        return .fullFrame
    }

    static func headAngles(fromHeadView headView: simd_float4x4) -> VRHeadAngles {
        let worldFromHead = simd_inverse(headView)
        let forward4 = worldFromHead * SIMD4<Float>(0, 0, -1, 0)
        let forward = SIMD3<Float>(forward4.x, forward4.y, forward4.z)
        let length = max(simd_length(forward), epsilon)
        return VRHeadAngles(
            yaw: atan2(forward.x, -forward.z),
            pitch: asin(clamped(forward.y / length, lower: -1, upper: 1))
        )
    }

    static func relativeAngles(
        _ angles: VRHeadAngles,
        reference: VRHeadAngles
    ) -> VRHeadAngles {
        VRHeadAngles(
            yaw: shortestAngle(angles.yaw - reference.yaw),
            pitch: angles.pitch - reference.pitch
        )
    }

    private static func safeAspect(size: SIMD2<Float>) -> Float {
        guard size.x.isFinite, size.y.isFinite, size.x > epsilon, size.y > epsilon else { return 1 }
        return size.x / size.y
    }

    private static func normalized(_ value: Float, maximum: Float) -> Float {
        guard maximum > epsilon else { return 0 }
        return clamped(value / maximum, lower: -1, upper: 1)
    }

    private static func shortestAngle(_ angle: Float) -> Float {
        var wrapped = fmod(angle + .pi, 2 * .pi)
        if wrapped < 0 {
            wrapped += 2 * .pi
        }
        return wrapped - .pi
    }

    private static func clamped(_ value: Float, lower: Float, upper: Float) -> Float {
        min(max(value, lower), upper)
    }
}
