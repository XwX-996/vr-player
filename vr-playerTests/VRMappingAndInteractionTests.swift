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
        XCTAssertEqual(VRUVMapping.videoCoordinate(surfaceCoordinate: source, eye: 0, layout: .topBottom), SIMD2(0.25, 0.375))
        XCTAssertEqual(VRUVMapping.videoCoordinate(surfaceCoordinate: source, eye: 1, layout: .topBottom), SIMD2(0.25, 0.875))
    }

    func testDisplayGeometryMatchesRecordedEndpoints() {
        var preferences = VRPlayerPreferences.default
        preferences.eyeScale = 0
        preferences.eyeAspect = 0
        let minimum = VRDisplayGeometry.viewport(eye: 0, preferences: preferences)
        XCTAssertEqual(minimum.width, 0.1, accuracy: 0.0001)
        XCTAssertEqual(minimum.height, 0.11, accuracy: 0.0001)

        preferences.eyeScale = 100
        preferences.eyeAspect = 100
        preferences.pupilDistance = 0
        let maximum = VRDisplayGeometry.viewport(eye: 1, preferences: preferences)
        XCTAssertEqual(maximum.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(maximum.y, 0, accuracy: 0.0001)
        XCTAssertEqual(maximum.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(maximum.height, 1, accuracy: 0.0001)

        preferences.vrGlassesEnabled = false
        XCTAssertEqual(
            VRDisplayGeometry.viewport(eye: 0, preferences: preferences),
            VRNormalizedViewport(x: 0, y: 0, width: 1, height: 1)
        )
    }

    func testPupilDistanceMovesEyeViewportsInOppositeDirections() {
        var preferences = VRPlayerPreferences.default
        preferences.eyeScale = 100

        preferences.pupilDistance = -100
        let inwardLeft = VRDisplayGeometry.viewport(eye: 0, preferences: preferences)
        let inwardRight = VRDisplayGeometry.viewport(eye: 1, preferences: preferences)
        XCTAssertEqual(inwardLeft.x, 0.05, accuracy: 0.0001)
        XCTAssertEqual(inwardRight.x, 0.45, accuracy: 0.0001)

        preferences.pupilDistance = 100
        let outwardLeft = VRDisplayGeometry.viewport(eye: 0, preferences: preferences)
        let outwardRight = VRDisplayGeometry.viewport(eye: 1, preferences: preferences)
        XCTAssertEqual(outwardLeft.x, -0.05, accuracy: 0.0001)
        XCTAssertEqual(outwardRight.x, 0.55, accuracy: 0.0001)
    }

    func testGlobalPreferencesDecodeMissingFieldsAndNormalizeValues() throws {
        let data = try XCTUnwrap("{\"projection\":\"hemisphere180\",\"eyeScale\":900,\"playbackRate\":1.7}".data(using: .utf8))
        let preferences = VRPlayerPreferences.decode(data)

        XCTAssertEqual(preferences.projection, .hemisphere180)
        XCTAssertEqual(preferences.stereoLayout, .mono)
        XCTAssertEqual(preferences.eyeScale, 100)
        XCTAssertEqual(preferences.pupilDistance, -14)
        XCTAssertEqual(preferences.distortionStrength, 0)
        XCTAssertEqual(preferences.edgeCorrection, 0)
        XCTAssertEqual(preferences.playbackRate, 1.5)
    }

    func testDistortionAdjustmentsClampAndScaleCoefficientsRelativeToProfile() {
        let preferences = VRPlayerPreferences.decode(
            Data(#"{"distortionStrength":90,"edgeCorrection":-90}"#.utf8)
        )
        XCTAssertEqual(preferences.distortionStrength, 50)
        XCTAssertEqual(preferences.edgeCorrection, -50)

        XCTAssertEqual(VRDistortionTuning.multiplier(for: -50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(VRDistortionTuning.multiplier(for: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(VRDistortionTuning.multiplier(for: 50), 1.5, accuracy: 0.0001)
        XCTAssertEqual(
            VRDistortionTuning.coefficient(base: 0.441, adjustment: 50),
            0.6615,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VRDistortionTuning.coefficient(base: 0.156, adjustment: -50),
            0.078,
            accuracy: 0.0001
        )
    }

    func testDistortionPreferencesRoundTripIntoRenderSettings() {
        var preferences = VRPlayerPreferences.default
        preferences.distortionStrength = 24
        preferences.edgeCorrection = -18

        let decoded = VRPlayerPreferences.decode(preferences.encoded())
        XCTAssertEqual(decoded.distortionStrength, 24)
        XCTAssertEqual(decoded.edgeCorrection, -18)

        let settings = VRRenderSettings(preferences: decoded)
        XCTAssertEqual(settings.distortionStrength, 24)
        XCTAssertEqual(settings.edgeCorrection, -18)
        XCTAssertEqual(settings.preferences.distortionStrength, 24)
        XCTAssertEqual(settings.preferences.edgeCorrection, -18)
    }

    func testLegacyPresentationPreferencesMigrateToExpectedModes() throws {
        let panorama = VRPlayerPreferences.decode(Data(#"{"panoramaEnabled":true,"vrGlassesEnabled":false}"#.utf8))
        XCTAssertEqual(panorama.presentationMode, .panorama)

        let legacyThreeD = VRPlayerPreferences.decode(Data(#"{"panoramaEnabled":false,"vrGlassesEnabled":true}"#.utf8))
        XCTAssertEqual(legacyThreeD.presentationMode, .threeD)
        XCTAssertEqual(legacyThreeD.threeDMode, .fit)

        let flat = VRPlayerPreferences.decode(Data(#"{"panoramaEnabled":false,"vrGlassesEnabled":false}"#.utf8))
        XCTAssertEqual(flat.presentationMode, .flat)
    }

    func testNewPresentationPreferenceWinsAndThreeDStylePersistsWhileDisabled() {
        let data = Data(#"{"presentationMode":"flat","threeDMode":"fill","panoramaEnabled":true,"vrGlassesEnabled":true}"#.utf8)
        var preferences = VRPlayerPreferences.decode(data)
        XCTAssertEqual(preferences.presentationMode, .flat)
        XCTAssertEqual(preferences.threeDMode, .fill)

        preferences.threeDEnabled = true
        XCTAssertEqual(preferences.presentationMode, .threeD)
        XCTAssertEqual(preferences.threeDMode, .fill)
        preferences.threeDEnabled = false
        XCTAssertEqual(preferences.presentationMode, .flat)
        XCTAssertEqual(preferences.threeDMode, .fill)
    }

    func testEffectiveRenderingRulesForFlatPanoramaAndThreeD() {
        var preferences = VRPlayerPreferences.default
        preferences.stereoLayout = .sideBySide
        preferences.vrGlassesEnabled = false

        preferences.presentationMode = .flat
        var settings = VRRenderSettings(preferences: preferences)
        XCTAssertFalse(settings.usesDualEyeViewports)
        XCTAssertEqual(settings.effectiveStereoLayout, .mono)

        preferences.presentationMode = .panorama
        settings = VRRenderSettings(preferences: preferences)
        XCTAssertFalse(settings.usesDualEyeViewports)
        XCTAssertEqual(settings.effectiveStereoLayout, .sideBySide)

        preferences.vrGlassesEnabled = true
        settings = VRRenderSettings(preferences: preferences)
        XCTAssertTrue(settings.usesDualEyeViewports)

        preferences.presentationMode = .threeD
        preferences.vrGlassesEnabled = false
        settings = VRRenderSettings(preferences: preferences)
        XCTAssertTrue(settings.usesDualEyeViewports)
        XCTAssertEqual(settings.effectiveStereoLayout, .mono)
        XCTAssertTrue(settings.renderPreferences.vrGlassesEnabled)
    }

    func testInvalidGlobalPreferencesFallBackToDefaults() {
        XCTAssertEqual(VRPlayerPreferences.decode(Data("invalid".utf8)), .default)
    }

    func testPlaybackEndActionRespectsRepeatSetting() {
        XCTAssertEqual(PlaybackControl.endAction(repeatsCurrentItem: false), .finish)
        XCTAssertEqual(PlaybackControl.endAction(repeatsCurrentItem: true), .repeatCurrent)
    }

    func testAspectFitCentersWideTallAndMatchingVideoWithoutCropping() {
        let wide = VRFlatVideoLayout.fit(sourceSize: SIMD2(16, 9), viewportSize: SIMD2(1, 1))
        XCTAssertEqual(wide.positionScale.x, 1, accuracy: 0.0001)
        XCTAssertEqual(wide.positionScale.y, 9.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(wide.uvOrigin, SIMD2(0, 0))
        XCTAssertEqual(wide.uvSize, SIMD2(1, 1))

        let tall = VRFlatVideoLayout.fit(sourceSize: SIMD2(9, 16), viewportSize: SIMD2(1, 1))
        XCTAssertEqual(tall.positionScale.x, 9.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(tall.positionScale.y, 1, accuracy: 0.0001)
        XCTAssertEqual(tall.uvOrigin, SIMD2(0, 0))
        XCTAssertEqual(tall.uvSize, SIMD2(1, 1))

        XCTAssertEqual(
            VRFlatVideoLayout.fit(sourceSize: SIMD2(4, 3), viewportSize: SIMD2(8, 6)),
            .fullFrame
        )
    }

    func testAspectFillWideVideoRespondsOnlyToYawAndClampsAtEdges() {
        let fieldOfView = VRFieldOfView(horizontalHalfAngle: .pi / 4, verticalHalfAngle: .pi / 4)
        let source = SIMD2<Float>(4, 1)
        let viewport = SIMD2<Float>(1, 1)
        let maximumYaw = atan(Float(4)) - Float.pi / 4

        let centered = VRFlatVideoLayout.fill(
            sourceSize: source,
            viewportSize: viewport,
            headAngles: .zero,
            referenceAngles: .zero,
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(centered.uvOrigin.x, 0.375, accuracy: 0.0001)
        XCTAssertEqual(centered.uvOrigin.y, 0, accuracy: 0.0001)
        XCTAssertEqual(centered.uvSize, SIMD2(0.25, 1))

        let pitchOnly = fillGeometry(
            source: source,
            viewport: viewport,
            head: VRHeadAngles(yaw: 0, pitch: 1),
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(pitchOnly, centered)

        let rightEdge = fillGeometry(
            source: source,
            viewport: viewport,
            head: VRHeadAngles(yaw: maximumYaw * 2, pitch: 0),
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(rightEdge.uvOrigin.x, 0.75, accuracy: 0.0001)
        assertUVInRange(rightEdge)

        let leftEdge = fillGeometry(
            source: source,
            viewport: viewport,
            head: VRHeadAngles(yaw: -maximumYaw * 2, pitch: 0),
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(leftEdge.uvOrigin.x, 0, accuracy: 0.0001)
        assertUVInRange(leftEdge)
    }

    func testAspectFillTallVideoRespondsOnlyToPitchAndLookingUpMovesCropUp() {
        let fieldOfView = VRFieldOfView(horizontalHalfAngle: .pi / 4, verticalHalfAngle: .pi / 4)
        let source = SIMD2<Float>(1, 4)
        let viewport = SIMD2<Float>(1, 1)
        let maximumPitch = atan(Float(4)) - Float.pi / 4

        let centered = fillGeometry(source: source, viewport: viewport, head: .zero, fieldOfView: fieldOfView)
        XCTAssertEqual(centered.uvOrigin.y, 0.375, accuracy: 0.0001)
        XCTAssertEqual(centered.uvSize, SIMD2(1, 0.25))

        let yawOnly = fillGeometry(
            source: source,
            viewport: viewport,
            head: VRHeadAngles(yaw: 1, pitch: 0),
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(yawOnly, centered)

        let upperEdge = fillGeometry(
            source: source,
            viewport: viewport,
            head: VRHeadAngles(yaw: 0, pitch: maximumPitch * 10),
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(upperEdge.uvOrigin.y, 0, accuracy: 0.0001)
        assertUVInRange(upperEdge)

        let lowerEdge = fillGeometry(
            source: source,
            viewport: viewport,
            head: VRHeadAngles(yaw: 0, pitch: -maximumPitch * 10),
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(lowerEdge.uvOrigin.y, 0.75, accuracy: 0.0001)
        assertUVInRange(lowerEdge)
    }

    func testAspectFillMatchingRatioDoesNotMoveAndBothEyesShareGeometry() {
        let fieldOfView = VRFieldOfView(horizontalHalfAngle: 0.6, verticalHalfAngle: 0.4)
        let head = VRHeadAngles(yaw: 2, pitch: -2)
        let leftEye = fillGeometry(
            source: SIMD2(16, 9),
            viewport: SIMD2(16, 9),
            head: head,
            fieldOfView: fieldOfView
        )
        let rightEye = fillGeometry(
            source: SIMD2(16, 9),
            viewport: SIMD2(16, 9),
            head: head,
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(leftEye, .fullFrame)
        XCTAssertEqual(rightEye, leftEye)
    }

    func testFillRecenterAndYawWrappingUseRelativeAngles() {
        let fieldOfView = VRFieldOfView(horizontalHalfAngle: .pi / 4, verticalHalfAngle: .pi / 4)
        let reference = VRHeadAngles(yaw: 0.7, pitch: -0.3)
        let recentered = VRFlatVideoLayout.fill(
            sourceSize: SIMD2(4, 1),
            viewportSize: SIMD2(1, 1),
            headAngles: reference,
            referenceAngles: reference,
            fieldOfView: fieldOfView
        )
        XCTAssertEqual(recentered.uvOrigin.x, 0.375, accuracy: 0.0001)

        let wrappedRight = VRFlatVideoLayout.fill(
            sourceSize: SIMD2(4, 1),
            viewportSize: SIMD2(1, 1),
            headAngles: VRHeadAngles(yaw: -.pi + 0.04, pitch: 0),
            referenceAngles: VRHeadAngles(yaw: .pi - 0.04, pitch: 0),
            fieldOfView: fieldOfView
        )
        XCTAssertGreaterThan(wrappedRight.uvOrigin.x, 0.375)
    }

    func testHeadAngleExtractionIgnoresRoll() {
        let angle: Float = 0.8
        let roll = simd_float4x4(
            SIMD4<Float>(cos(angle), sin(angle), 0, 0),
            SIMD4<Float>(-sin(angle), cos(angle), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        XCTAssertEqual(VRFlatVideoLayout.headAngles(fromHeadView: roll), .zero)
    }

    func testHeadAngleExtractionUsesPositiveYawForRightAndPositivePitchForUp() {
        let right = VRFlatVideoLayout.headAngles(fromHeadView: .rotationY(0.3))
        XCTAssertEqual(right.yaw, 0.3, accuracy: 0.0001)
        XCTAssertEqual(right.pitch, 0, accuracy: 0.0001)

        let up = VRFlatVideoLayout.headAngles(fromHeadView: .rotationX(-0.25))
        XCTAssertEqual(up.yaw, 0, accuracy: 0.0001)
        XCTAssertEqual(up.pitch, 0.25, accuracy: 0.0001)
    }

    func testConservativeFieldOfViewUsesNarrowerProjectionForEachAxis() throws {
        let wide = simd_float4x4.perspective(
            verticalFieldOfView: .pi / 2,
            aspectRatio: 2,
            near: 0.01,
            far: 10
        )
        let narrow = simd_float4x4.perspective(
            verticalFieldOfView: .pi / 3,
            aspectRatio: 1,
            near: 0.01,
            far: 10
        )
        let result = try XCTUnwrap(VRFieldOfView.conservative(projections: [wide, narrow]))
        XCTAssertEqual(result.horizontalHalfAngle, .pi / 6, accuracy: 0.0001)
        XCTAssertEqual(result.verticalHalfAngle, .pi / 6, accuracy: 0.0001)
    }

    func testPlaybackScrubStateKeepsDragPositionUntilCommit() {
        var state = PlaybackScrubState()
        XCTAssertEqual(state.displayedPosition(playbackPosition: 12, duration: 100), 12)

        state.begin(at: 12, duration: 100)
        state.update(to: 64, duration: 100)
        XCTAssertEqual(state.displayedPosition(playbackPosition: 13, duration: 100), 64)
        XCTAssertEqual(state.finish(), 64)
        XCTAssertEqual(state.displayedPosition(playbackPosition: 13, duration: 100), 13)

        state.update(to: 120, duration: 100)
        XCTAssertEqual(state.finish(), 100)
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

    func testHUDCylinderPreservesAngularCoverageAndDistance() {
        XCTAssertEqual(VRHUDGeometry.horizontalSegmentCount, 64)
        XCTAssertEqual(VRHUDGeometry.panelDistance, 1.75, accuracy: 0.0001)
        XCTAssertEqual(
            VRHUDGeometry.horizontalRadians,
            2 * atan(VRHUDGeometry.referencePanelWidth / (2 * VRHUDGeometry.panelDistance)),
            accuracy: 0.0001
        )

        let headPosition = SIMD3<Float>(0, 0, VRHUDGeometry.panelDistance)
        let topCenter = VRHUDGeometry.surfacePoint(textureCoordinate: SIMD2(0.5, 0))
        let topLeft = VRHUDGeometry.surfacePoint(textureCoordinate: SIMD2(0, 0))
        let topRight = VRHUDGeometry.surfacePoint(textureCoordinate: SIMD2(1, 0))
        let topCenterDistance = simd_length(topCenter - headPosition)

        XCTAssertEqual(simd_length(topLeft - headPosition), topCenterDistance, accuracy: 0.0001)
        XCTAssertEqual(simd_length(topRight - headPosition), topCenterDistance, accuracy: 0.0001)
        XCTAssertEqual(topLeft.x, -topRight.x, accuracy: 0.0001)
        XCTAssertEqual(topLeft.z, topRight.z, accuracy: 0.0001)
    }

    func testHUDCylinderMapsCenterAndCornersBackToTextureCoordinates() {
        let rayOrigin = SIMD3<Float>(0, 0, VRHUDGeometry.panelDistance)
        let textureCoordinates: [SIMD2<Float>] = [
            SIMD2(0, 0),
            SIMD2(1, 0),
            SIMD2(0.5, 0.5),
            SIMD2(0, 1),
            SIMD2(1, 1),
        ]

        for expected in textureCoordinates {
            let target = VRHUDGeometry.surfacePoint(textureCoordinate: expected)
            let actual = VRHUDGeometry.textureCoordinate(
                rayOrigin: rayOrigin,
                rayDirection: target - rayOrigin
            )
            XCTAssertEqual(actual?.x ?? -1, expected.x, accuracy: 0.0001)
            XCTAssertEqual(actual?.y ?? -1, expected.y, accuracy: 0.0001)
        }
    }

    func testHUDCylinderRejectsRaysOutsideVisibleSurface() {
        let radius = VRHUDGeometry.panelDistance
        let rayOrigin = SIMD3<Float>(0, 0, radius)
        let outsideAngle = VRHUDGeometry.horizontalRadians / 2 + 0.1
        let outsideArcDirection = SIMD3<Float>(
            radius * sin(outsideAngle),
            0,
            -radius * cos(outsideAngle)
        )

        XCTAssertNil(VRHUDGeometry.textureCoordinate(
            rayOrigin: rayOrigin,
            rayDirection: outsideArcDirection
        ))
        XCTAssertNil(VRHUDGeometry.textureCoordinate(
            rayOrigin: rayOrigin,
            rayDirection: SIMD3(0, VRHUDGeometry.panelHeight, -radius)
        ))
        XCTAssertNil(VRHUDGeometry.textureCoordinate(
            rayOrigin: rayOrigin,
            rayDirection: SIMD3(0, 0, 1)
        ))
        XCTAssertNil(VRHUDGeometry.textureCoordinate(
            rayOrigin: rayOrigin,
            rayDirection: SIMD3(0, 1, 0)
        ))
        XCTAssertNil(VRHUDGeometry.textureCoordinate(
            rayOrigin: SIMD3(radius * 2, 0, radius),
            rayDirection: SIMD3(0, 0, -1)
        ))
    }

    func testHUDCylinderSurfaceAndRayMappingRoundTrip() {
        let rayOrigin = SIMD3<Float>(0, 0, VRHUDGeometry.panelDistance)
        let values: [Float] = [0.05, 0.25, 0.5, 0.75, 0.95]

        for u in values {
            for v in values {
                let expected = SIMD2<Float>(u, v)
                let target = VRHUDGeometry.surfacePoint(textureCoordinate: expected)
                let actual = VRHUDGeometry.textureCoordinate(
                    rayOrigin: rayOrigin,
                    rayDirection: target - rayOrigin
                )
                XCTAssertEqual(actual?.x ?? -1, expected.x, accuracy: 0.0001)
                XCTAssertEqual(actual?.y ?? -1, expected.y, accuracy: 0.0001)
            }
        }
    }

    func testDefaultDwellActivatesAfterOneSecondAndLatches() {
        var tracker = GazeDwellTracker()
        let hit = VRControlHit(target: .playPause, value: nil)

        XCTAssertNil(tracker.update(hit: hit, at: 10))
        XCTAssertNil(tracker.update(hit: hit, at: 10.99))
        XCTAssertEqual(tracker.progress, 0.99, accuracy: 0.001)
        XCTAssertEqual(tracker.update(hit: hit, at: 11)?.target, .playPause)
        XCTAssertNil(tracker.update(hit: hit, at: 12))
    }

    func testLeavingDwellTargetResetsProgressAndRequiresFreshSecond() {
        var tracker = GazeDwellTracker()
        let hit = VRControlHit(target: .playPause, value: nil)

        XCTAssertNil(tracker.update(hit: hit, at: 13))
        XCTAssertNil(tracker.update(hit: hit, at: 13.75))
        XCTAssertNil(tracker.update(hit: nil, at: 14))
        XCTAssertNil(tracker.target)
        XCTAssertEqual(tracker.progress, 0)
        XCTAssertNil(tracker.update(hit: hit, at: 15))
        XCTAssertNil(tracker.update(hit: hit, at: 15.99))
        XCTAssertEqual(tracker.update(hit: hit, at: 16)?.target, .playPause)
    }

    func testSwitchingDwellTargetsRestartsProgress() {
        var tracker = GazeDwellTracker()
        let playPause = VRControlHit(target: .playPause, value: nil)
        let next = VRControlHit(target: .next, value: nil)

        XCTAssertNil(tracker.update(hit: playPause, at: 20))
        XCTAssertNil(tracker.update(hit: playPause, at: 20.75))
        XCTAssertNil(tracker.update(hit: next, at: 20.76))
        XCTAssertEqual(tracker.target, .next)
        XCTAssertEqual(tracker.progress, 0)
        XCTAssertNil(tracker.update(hit: next, at: 21.75))
        XCTAssertEqual(tracker.update(hit: next, at: 21.76)?.target, .next)
    }

    func testProgressAndModeHitTargets() {
        let state = sampleHUDState()
        let seek = VRHUDLayout.hitTest(state: state, point: SIMD2(0.5, 0.42))
        XCTAssertEqual(seek?.target, .seek)
        XCTAssertEqual(seek?.value ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.12, 0.61))?.target, .projection180)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.27, 0.61))?.target, .projection360)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.42, 0.61))?.target, .threeDFit)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.57, 0.61))?.target, .threeDFill)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.73, 0.61))?.target, .mono)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.88, 0.61))?.target, .sideBySide)
    }

    func testHUDModeTargetsDoNotOverlapAndSBSIsDisabledInThreeD() {
        let modeRects = [
            VRHUDLayout.projection180,
            VRHUDLayout.projection360,
            VRHUDLayout.threeDFit,
            VRHUDLayout.threeDFill,
            VRHUDLayout.mono,
            VRHUDLayout.sideBySide,
        ]
        for pair in zip(modeRects, modeRects.dropFirst()) {
            XCTAssertLessThan(pair.0.maxX, pair.1.minX)
        }

        var state = sampleHUDState()
        state.presentationMode = .threeD
        state.stereoLayout = .sideBySide
        XCTAssertEqual(state.effectiveStereoLayout, .mono)
        XCTAssertNil(VRHUDLayout.hitTest(state: state, point: SIMD2(0.88, 0.61)))
    }

    func testNavigationControlHitTargets() {
        var state = sampleHUDState()

        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.10, 0.05))?.target, .back)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.80, 0.05))?.target, .recenter)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.90, 0.05))?.target, .hideControls)

        state.mode = .playlist
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.08, 0.10))?.target, .playlistBack)
        XCTAssertEqual(VRHUDLayout.hitTest(state: state, point: SIMD2(0.90, 0.05))?.target, .hideControls)
    }

    func testHeadGestureTriggersForOppositeRelativeExcursions() {
        var detector = HeadGestureDetector(
            excursionRadians: 0.1,
            neutralBandRadians: 0.02,
            maximumGestureDuration: 1.5,
            cooldown: 0
        )

        XCTAssertFalse(detector.observe(pitch: 0.4, at: 0))
        XCTAssertFalse(detector.observe(pitch: 0.48, at: 0.1))
        XCTAssertFalse(detector.observe(pitch: 0.52, at: 0.2))
        XCTAssertTrue(detector.observe(pitch: 0.28, at: 0.8))
    }

    func testHeadGestureRejectsSlowOrSameDirectionMovement() {
        var detector = HeadGestureDetector(
            excursionRadians: 0.1,
            neutralBandRadians: 0.02,
            maximumGestureDuration: 1,
            cooldown: 0
        )

        XCTAssertFalse(detector.observe(pitch: 0, at: 0))
        XCTAssertFalse(detector.observe(pitch: 0.12, at: 0.1))
        XCTAssertFalse(detector.observe(pitch: 0.16, at: 0.2))
        XCTAssertFalse(detector.observe(pitch: -0.12, at: 1.2))
    }

    func testHeadGestureRequiresReturningToNeutralBeforeRearming() {
        var detector = HeadGestureDetector(
            excursionRadians: 0.1,
            neutralBandRadians: 0.02,
            maximumGestureDuration: 1.5,
            cooldown: 0
        )

        XCTAssertFalse(detector.observe(pitch: 0, at: 0))
        XCTAssertFalse(detector.observe(pitch: 0.12, at: 0.1))
        XCTAssertTrue(detector.observe(pitch: -0.12, at: 0.2))
        XCTAssertFalse(detector.observe(pitch: 0.12, at: 0.3))
        XCTAssertFalse(detector.observe(pitch: 0, at: 0.4))
        XCTAssertFalse(detector.observe(pitch: 0.12, at: 0.5))
        XCTAssertTrue(detector.observe(pitch: -0.12, at: 0.6))
    }

    func testHeadGestureResetCapturesANewReferencePitch() {
        var detector = HeadGestureDetector(
            excursionRadians: 0.1,
            neutralBandRadians: 0.02,
            maximumGestureDuration: 1.5,
            cooldown: 0
        )

        XCTAssertFalse(detector.observe(pitch: 0.4, at: 0))
        XCTAssertFalse(detector.observe(pitch: 0.52, at: 0.1))
        detector.reset()
        XCTAssertFalse(detector.observe(pitch: -0.3, at: 0.2))
        XCTAssertFalse(detector.observe(pitch: -0.18, at: 0.3))
        XCTAssertTrue(detector.observe(pitch: -0.42, at: 0.4))
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
            presentationMode: .panorama,
            threeDMode: .fit,
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

    private func fillGeometry(
        source: SIMD2<Float>,
        viewport: SIMD2<Float>,
        head: VRHeadAngles,
        fieldOfView: VRFieldOfView
    ) -> VRFlatVideoGeometry {
        VRFlatVideoLayout.fill(
            sourceSize: source,
            viewportSize: viewport,
            headAngles: head,
            referenceAngles: .zero,
            fieldOfView: fieldOfView
        )
    }

    private func assertUVInRange(
        _ geometry: VRFlatVideoGeometry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(geometry.uvOrigin.x, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(geometry.uvOrigin.y, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(geometry.uvOrigin.x + geometry.uvSize.x, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(geometry.uvOrigin.y + geometry.uvSize.y, 1, file: file, line: line)
    }

}
