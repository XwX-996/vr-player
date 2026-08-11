import XCTest
import simd
@testable import vr_player

final class VRMappingAndInteractionTests: XCTestCase {
    func testProjectionHorizontalCoverage() {
        XCTAssertEqual(VRUVMapping.horizontalRadians(for: .hemisphere180), .pi, accuracy: 0.0001)
        XCTAssertEqual(VRUVMapping.horizontalRadians(for: .sphere360), .pi * 2, accuracy: 0.0001)
    }

    func testMonoAndSideBySideCoordinates() {
        let source = SIMD2<Float>(0.25, 0.75)
        XCTAssertEqual(VRUVMapping.videoCoordinate(surfaceCoordinate: source, eye: 0, layout: .mono), source)
        XCTAssertEqual(VRUVMapping.videoCoordinate(surfaceCoordinate: source, eye: 0, layout: .sideBySide), SIMD2(0.125, 0.75))
        XCTAssertEqual(VRUVMapping.videoCoordinate(surfaceCoordinate: source, eye: 1, layout: .sideBySide), SIMD2(0.625, 0.75))
    }

    func testInterfaceOrientationMapsToPhysicalDeviceOrientation() {
        XCTAssertEqual(VROrientationMapping.deviceOrientation(for: .landscapeLeft), .landscapeRight)
        XCTAssertEqual(VROrientationMapping.deviceOrientation(for: .landscapeRight), .landscapeLeft)
        XCTAssertEqual(VROrientationMapping.deviceOrientation(for: .portrait), .portrait)
    }

    func testCardboardProjectionRemapsOpenGLDepthToMetalDepth() {
        let near: Float = 0.1
        let far: Float = 100
        let openGLProjection = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, (far + near) / (near - far), -1),
            SIMD4<Float>(0, 0, (2 * near * far) / (near - far), 0)
        )
        let metalProjection = VRPoseMath.metalProjection(
            fromCardboardProjection: openGLProjection
        )

        XCTAssertEqual(ndcDepth(matrix: metalProjection, z: -near), 0, accuracy: 0.0001)
        XCTAssertEqual(ndcDepth(matrix: metalProjection, z: -far), 1, accuracy: 0.0001)
    }

    func testFallbackPerspectiveUsesRightHandedNegativeZAndMetalDepth() {
        let near: Float = 0.1
        let far: Float = 100
        let projection = simd_float4x4.perspective(
            verticalFieldOfView: .pi / 2,
            aspectRatio: 1,
            near: near,
            far: far
        )

        XCTAssertEqual(ndcDepth(matrix: projection, z: -near), 0, accuracy: 0.0001)
        XCTAssertEqual(ndcDepth(matrix: projection, z: -far), 1, accuracy: 0.0001)
        XCTAssertGreaterThan((projection * SIMD4<Float>(0, 0, -1, 1)).w, 0)
    }

    func testEyeFromHeadOffsetsAreAppliedWithOppositeSigns() {
        let halfIPD: Float = 0.032
        let left = VRPoseMath.eyeViewProjection(
            projection: matrix_identity_float4x4,
            eyeFromHead: .translation(x: halfIPD, y: 0, z: 0),
            headView: matrix_identity_float4x4
        )
        let right = VRPoseMath.eyeViewProjection(
            projection: matrix_identity_float4x4,
            eyeFromHead: .translation(x: -halfIPD, y: 0, z: 0),
            headView: matrix_identity_float4x4
        )

        XCTAssertEqual(left.columns.3.x, halfIPD, accuracy: 0.0001)
        XCTAssertEqual(right.columns.3.x, -halfIPD, accuracy: 0.0001)
    }

    func testFrameTimingTargetsTheNextRefresh() {
        XCTAssertEqual(
            VRFrameTiming.nextPresentationTime(now: 10, framesPerSecond: 120),
            10 + 1.0 / 120.0,
            accuracy: 0.000_001
        )
    }

    func testDwellActivatesOnlyAfterTwoSecondsAndLatches() {
        var tracker = GazeDwellTracker(dwellDuration: 2)
        let hit = VRControlHit(target: .playPause, value: nil)

        XCTAssertNil(tracker.update(hit: hit, at: 10))
        XCTAssertNil(tracker.update(hit: hit, at: 11.99))
        XCTAssertEqual(tracker.progress, 0.995, accuracy: 0.001)
        XCTAssertEqual(tracker.update(hit: hit, at: 12)?.target, .playPause)
        XCTAssertNil(tracker.update(hit: hit, at: 13))

        XCTAssertNil(tracker.update(hit: nil, at: 14))
        XCTAssertNil(tracker.update(hit: hit, at: 15))
        XCTAssertEqual(tracker.update(hit: hit, at: 17)?.target, .playPause)
    }

    func testProgressAndModeHitTargets() {
        let state = sampleHUDState()
        let seek = VRHUDLayout.hitTest(state: state, point: SIMD2(0.5, 0.42))
        XCTAssertEqual(seek?.target, .seek)
        XCTAssertEqual(seek?.value ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.24, 0.61))?.target, .projection180)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.75, 0.61))?.target, .sideBySide)
    }

    private func sampleHUDState() -> VRHUDState {
        VRHUDState(
            mode: .main,
            isPlaying: true,
            position: 20,
            duration: 100,
            bufferedFraction: 0.4,
            projection: .sphere360,
            stereoLayout: .mono,
            brightness: 0.5,
            volume: 0.5,
            playlistEntries: [],
            playlistPage: 0,
            playlistPageCount: 1
        )
    }

    private func ndcDepth(matrix: simd_float4x4, z: Float) -> Float {
        let clip = matrix * SIMD4<Float>(0, 0, z, 1)
        return clip.z / clip.w
    }

}
