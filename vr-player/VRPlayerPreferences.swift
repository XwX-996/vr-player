import Foundation

nonisolated enum VRDisplayMode: String, Codable, CaseIterable, Sendable {
    case fishEye
    case flat
}

nonisolated enum VRPresentationMode: String, Codable, CaseIterable, Sendable {
    case flat
    case panorama
    case threeD
}

nonisolated enum VRThreeDMode: String, Codable, CaseIterable, Sendable {
    case fit
    case fill
}

nonisolated enum VRDistortionTuning {
    static let adjustmentRange = -50...50

    static func normalizedAdjustment(_ value: Int) -> Int {
        value.clamped(to: adjustmentRange)
    }

    static func multiplier(for adjustment: Int) -> Float {
        1 + Float(normalizedAdjustment(adjustment)) / 100
    }

    static func coefficient(base: Float, adjustment: Int) -> Float {
        base * multiplier(for: adjustment)
    }
}

nonisolated struct VRPlayerPreferences: Codable, Equatable, Sendable {
    static let storageKey = "vr-player.global-preferences.v1"

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
    var repeatsCurrentItem: Bool
    var playbackRate: Double

    static let `default` = VRPlayerPreferences(
        projection: .sphere360,
        stereoLayout: .mono,
        presentationMode: .panorama,
        threeDMode: .fit,
        vrGlassesEnabled: true,
        displayMode: .fishEye,
        distortionStrength: 0,
        edgeCorrection: 0,
        pupilDistance: -14,
        eyeDistance: 0,
        eyeAspect: 100,
        eyeScale: 100,
        brightness: 0,
        contrast: 0,
        saturation: 0,
        repeatsCurrentItem: false,
        playbackRate: 1
    )

    private enum CodingKeys: String, CodingKey {
        case projection
        case stereoLayout
        case presentationMode
        case threeDMode
        case vrGlassesEnabled
        case displayMode
        case distortionStrength
        case edgeCorrection
        case pupilDistance
        case eyeDistance
        case eyeAspect
        case eyeScale
        case brightness
        case contrast
        case saturation
        case repeatsCurrentItem
        case playbackRate
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case panoramaEnabled
    }

    init(
        projection: VRProjection,
        stereoLayout: StereoLayout,
        presentationMode: VRPresentationMode,
        threeDMode: VRThreeDMode,
        vrGlassesEnabled: Bool,
        displayMode: VRDisplayMode,
        distortionStrength: Int,
        edgeCorrection: Int,
        pupilDistance: Int,
        eyeDistance: Int,
        eyeAspect: Int,
        eyeScale: Int,
        brightness: Int,
        contrast: Int,
        saturation: Int,
        repeatsCurrentItem: Bool,
        playbackRate: Double
    ) {
        self.projection = projection
        self.stereoLayout = stereoLayout
        self.presentationMode = presentationMode
        self.threeDMode = threeDMode
        self.vrGlassesEnabled = vrGlassesEnabled
        self.displayMode = displayMode
        self.distortionStrength = distortionStrength
        self.edgeCorrection = edgeCorrection
        self.pupilDistance = pupilDistance
        self.eyeDistance = eyeDistance
        self.eyeAspect = eyeAspect
        self.eyeScale = eyeScale
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.repeatsCurrentItem = repeatsCurrentItem
        self.playbackRate = playbackRate
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projection = try container.decodeIfPresent(VRProjection.self, forKey: .projection) ?? defaults.projection
        stereoLayout = try container.decodeIfPresent(StereoLayout.self, forKey: .stereoLayout) ?? defaults.stereoLayout
        vrGlassesEnabled = try container.decodeIfPresent(Bool.self, forKey: .vrGlassesEnabled) ?? defaults.vrGlassesEnabled
        threeDMode = try container.decodeIfPresent(VRThreeDMode.self, forKey: .threeDMode) ?? defaults.threeDMode
        if let decodedMode = try container.decodeIfPresent(VRPresentationMode.self, forKey: .presentationMode) {
            presentationMode = decodedMode
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let panoramaEnabled = try legacy.decodeIfPresent(Bool.self, forKey: .panoramaEnabled) {
                presentationMode = panoramaEnabled ? .panorama : (vrGlassesEnabled ? .threeD : .flat)
            } else {
                presentationMode = defaults.presentationMode
            }
        }
        displayMode = try container.decodeIfPresent(VRDisplayMode.self, forKey: .displayMode) ?? defaults.displayMode
        distortionStrength = try container.decodeIfPresent(Int.self, forKey: .distortionStrength) ?? defaults.distortionStrength
        edgeCorrection = try container.decodeIfPresent(Int.self, forKey: .edgeCorrection) ?? defaults.edgeCorrection
        pupilDistance = try container.decodeIfPresent(Int.self, forKey: .pupilDistance) ?? defaults.pupilDistance
        eyeDistance = try container.decodeIfPresent(Int.self, forKey: .eyeDistance) ?? defaults.eyeDistance
        eyeAspect = try container.decodeIfPresent(Int.self, forKey: .eyeAspect) ?? defaults.eyeAspect
        eyeScale = try container.decodeIfPresent(Int.self, forKey: .eyeScale) ?? defaults.eyeScale
        brightness = try container.decodeIfPresent(Int.self, forKey: .brightness) ?? defaults.brightness
        contrast = try container.decodeIfPresent(Int.self, forKey: .contrast) ?? defaults.contrast
        saturation = try container.decodeIfPresent(Int.self, forKey: .saturation) ?? defaults.saturation
        repeatsCurrentItem = try container.decodeIfPresent(Bool.self, forKey: .repeatsCurrentItem) ?? defaults.repeatsCurrentItem
        playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? defaults.playbackRate
        normalize()
    }

    static func decode(_ data: Data) -> VRPlayerPreferences {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return .default
        }
        return decoded
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    mutating func normalize() {
        distortionStrength = VRDistortionTuning.normalizedAdjustment(distortionStrength)
        edgeCorrection = VRDistortionTuning.normalizedAdjustment(edgeCorrection)
        pupilDistance = pupilDistance.clamped(to: -100...100)
        eyeDistance = eyeDistance.clamped(to: 0...100)
        eyeAspect = eyeAspect.clamped(to: 0...100)
        eyeScale = eyeScale.clamped(to: 0...100)
        brightness = brightness.clamped(to: -100...100)
        contrast = contrast.clamped(to: -100...100)
        saturation = saturation.clamped(to: -100...100)
        playbackRate = [0.5, 0.75, 1, 1.25, 1.5, 2].min(by: {
            abs($0 - playbackRate) < abs($1 - playbackRate)
        }) ?? 1
    }

    var panoramaEnabled: Bool {
        get { presentationMode == .panorama }
        set { presentationMode = newValue ? .panorama : .flat }
    }

    var threeDEnabled: Bool {
        get { presentationMode == .threeD }
        set { presentationMode = newValue ? .threeD : .flat }
    }
}

nonisolated struct VRNormalizedViewport: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

nonisolated enum VRDisplayGeometry {
    private static let maximumPupilOffset = 0.05

    static func viewport(
        eye: Int,
        preferences: VRPlayerPreferences
    ) -> VRNormalizedViewport {
        guard preferences.vrGlassesEnabled else {
            return VRNormalizedViewport(x: 0, y: 0, width: 1, height: 1)
        }

        let scale = 0.2 + 0.8 * Double(preferences.eyeScale.clamped(to: 0...100)) / 100
        let aspect = 0.55 + 0.45 * Double(preferences.eyeAspect.clamped(to: 0...100)) / 100
        let width = 0.5 * scale
        let height = scale * aspect
        let safeEye = eye.clamped(to: 0...1)
        let halfOrigin = Double(safeEye) * 0.5
        let pupilOffset = Double(preferences.pupilDistance.clamped(to: -100...100)) / 100 * maximumPupilOffset
        let pupilDirection = safeEye == 0 ? -1.0 : 1.0
        return VRNormalizedViewport(
            x: halfOrigin + (0.5 - width) / 2 + pupilDirection * pupilOffset,
            y: (1 - height) / 2,
            width: width,
            height: height
        )
    }

    static func verticalFieldOfView(preferences: VRPlayerPreferences) -> Float {
        let amount = Float(preferences.eyeDistance.clamped(to: 0...100)) / 100
        return (.pi / 180) * (72 + amount * 34)
    }

}

private extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
