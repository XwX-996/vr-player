import simd

nonisolated enum VRUVMapping {
    static func horizontalRadians(for projection: VRProjection) -> Float {
        switch projection {
        case .sphere360:
            return .pi * 2
        case .hemisphere180:
            return .pi
        }
    }

    static func videoCoordinate(
        surfaceCoordinate: SIMD2<Float>,
        eye: Int,
        layout: StereoLayout
    ) -> SIMD2<Float> {
        switch layout {
        case .mono:
            return surfaceCoordinate
        case .sideBySide:
            return SIMD2(surfaceCoordinate.x * 0.5 + Float(eye) * 0.5, surfaceCoordinate.y)
        }
    }
}
