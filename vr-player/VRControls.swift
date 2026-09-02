import Foundation

nonisolated enum VRHUDMode: Equatable, Sendable {
    case main
    case playlist
}

nonisolated struct VRPlaylistEntry: Equatable, Sendable {
    let id: UUID
    let name: String
    let isCurrent: Bool
}

nonisolated struct VRHUDState: Equatable, Sendable {
    var mode: VRHUDMode
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var bufferedFraction: Double
    var projection: VRProjection
    var stereoLayout: StereoLayout
    var presentationMode: VRPresentationMode
    var threeDMode: VRThreeDMode
    var brightness: Double
    var volume: Double
    var playlistEntries: [VRPlaylistEntry]
    var playlistPage: Int
    var playlistPageCount: Int
    var recenterCountdown: Int? = nil

    var effectiveStereoLayout: StereoLayout {
        presentationMode == .panorama ? stereoLayout : .mono
    }
}

nonisolated enum VRControlTarget: Hashable, Sendable {
    case back
    case hideControls
    case recenter
    case previous
    case playPause
    case next
    case playlist
    case seek
    case projection180
    case projection360
    case threeDFit
    case threeDFill
    case mono
    case sideBySide
    case brightness
    case volume
    case playlistBack
    case playlistPreviousPage
    case playlistNextPage
    case playlistItem(UUID)
}

nonisolated struct VRControlHit: Equatable, Sendable {
    let target: VRControlTarget
    let value: Double?
}

nonisolated struct VRControlActivation: Sendable {
    let target: VRControlTarget
    let value: Double?
}

nonisolated struct VRNormalizedRect: Equatable, Sendable {
    let minX: Float
    let minY: Float
    let maxX: Float
    let maxY: Float

    func contains(_ point: SIMD2<Float>) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    func horizontalFraction(for point: SIMD2<Float>) -> Double {
        Double(min(max((point.x - minX) / max(maxX - minX, 0.001), 0), 1))
    }
}

nonisolated enum VRHUDLayout {
    static let back = VRNormalizedRect(minX: 0.06, minY: 0.005, maxX: 0.14, maxY: 0.105)
    static let recenter = VRNormalizedRect(minX: 0.76, minY: 0.005, maxX: 0.84, maxY: 0.105)
    static let hideControls = VRNormalizedRect(minX: 0.86, minY: 0.005, maxX: 0.94, maxY: 0.105)
    static let previous = VRNormalizedRect(minX: 0.10, minY: 0.11, maxX: 0.26, maxY: 0.31)
    static let playPause = VRNormalizedRect(minX: 0.30, minY: 0.11, maxX: 0.46, maxY: 0.31)
    static let next = VRNormalizedRect(minX: 0.50, minY: 0.11, maxX: 0.66, maxY: 0.31)
    static let playlist = VRNormalizedRect(minX: 0.72, minY: 0.11, maxX: 0.88, maxY: 0.31)
    static let progress = VRNormalizedRect(minX: 0.10, minY: 0.36, maxX: 0.90, maxY: 0.49)
    static let projection180 = VRNormalizedRect(minX: 0.05, minY: 0.54, maxX: 0.19, maxY: 0.68)
    static let projection360 = VRNormalizedRect(minX: 0.20, minY: 0.54, maxX: 0.34, maxY: 0.68)
    static let threeDFit = VRNormalizedRect(minX: 0.35, minY: 0.54, maxX: 0.49, maxY: 0.68)
    static let threeDFill = VRNormalizedRect(minX: 0.50, minY: 0.54, maxX: 0.65, maxY: 0.68)
    static let mono = VRNormalizedRect(minX: 0.66, minY: 0.54, maxX: 0.80, maxY: 0.68)
    static let sideBySide = VRNormalizedRect(minX: 0.81, minY: 0.54, maxX: 0.95, maxY: 0.68)
    static let brightness = VRNormalizedRect(minX: 0.10, minY: 0.76, maxX: 0.44, maxY: 0.90)
    static let volume = VRNormalizedRect(minX: 0.56, minY: 0.76, maxX: 0.90, maxY: 0.90)
    static let playlistBack = VRNormalizedRect(minX: 0.035, minY: 0.035, maxX: 0.13, maxY: 0.18)
    static let playlistPreviousPage = VRNormalizedRect(minX: 0.12, minY: 0.84, maxX: 0.30, maxY: 0.96)
    static let playlistNextPage = VRNormalizedRect(minX: 0.70, minY: 0.84, maxX: 0.88, maxY: 0.96)

    static func hitTest(state: VRHUDState, point: SIMD2<Float>) -> VRControlHit? {
        guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
        switch state.mode {
        case .main:
            if back.contains(point) { return VRControlHit(target: .back, value: nil) }
            if recenter.contains(point) { return VRControlHit(target: .recenter, value: nil) }
            if hideControls.contains(point) { return VRControlHit(target: .hideControls, value: nil) }
            if previous.contains(point) { return VRControlHit(target: .previous, value: nil) }
            if playPause.contains(point) { return VRControlHit(target: .playPause, value: nil) }
            if next.contains(point) { return VRControlHit(target: .next, value: nil) }
            if playlist.contains(point) { return VRControlHit(target: .playlist, value: nil) }
            if progress.contains(point) {
                return VRControlHit(target: .seek, value: progress.horizontalFraction(for: point))
            }
            if projection180.contains(point) { return VRControlHit(target: .projection180, value: nil) }
            if projection360.contains(point) { return VRControlHit(target: .projection360, value: nil) }
            if threeDFit.contains(point) { return VRControlHit(target: .threeDFit, value: nil) }
            if threeDFill.contains(point) { return VRControlHit(target: .threeDFill, value: nil) }
            if mono.contains(point) { return VRControlHit(target: .mono, value: nil) }
            if state.presentationMode != .threeD, sideBySide.contains(point) {
                return VRControlHit(target: .sideBySide, value: nil)
            }
            if brightness.contains(point) {
                return VRControlHit(target: .brightness, value: brightness.horizontalFraction(for: point))
            }
            if volume.contains(point) {
                return VRControlHit(target: .volume, value: volume.horizontalFraction(for: point))
            }
        case .playlist:
            if hideControls.contains(point) { return VRControlHit(target: .hideControls, value: nil) }
            if playlistBack.contains(point) { return VRControlHit(target: .playlistBack, value: nil) }
            for (index, entry) in state.playlistEntries.enumerated() {
                if playlistRow(index: index).contains(point) {
                    return VRControlHit(target: .playlistItem(entry.id), value: nil)
                }
            }
            if state.playlistPage > 0, playlistPreviousPage.contains(point) {
                return VRControlHit(target: .playlistPreviousPage, value: nil)
            }
            if state.playlistPage + 1 < state.playlistPageCount, playlistNextPage.contains(point) {
                return VRControlHit(target: .playlistNextPage, value: nil)
            }
        }
        return nil
    }

    static func playlistRow(index: Int) -> VRNormalizedRect {
        let top = Float(0.20 + Double(index) * 0.125)
        return VRNormalizedRect(minX: 0.12, minY: top, maxX: 0.88, maxY: top + 0.105)
    }
}

nonisolated struct GazeDwellTracker: Sendable {
    private(set) var target: VRControlTarget?
    private(set) var progress: Float = 0
    private var startedAt: TimeInterval = 0
    private var isLatched = false
    let dwellDuration: TimeInterval

    init(dwellDuration: TimeInterval = 1) {
        self.dwellDuration = dwellDuration
    }

    mutating func update(hit: VRControlHit?, at time: TimeInterval) -> VRControlActivation? {
        guard let hit else {
            reset()
            return nil
        }
        if hit.target != target {
            target = hit.target
            startedAt = time
            progress = 0
            isLatched = false
            return nil
        }
        guard !isLatched else { return nil }
        progress = Float(min(max((time - startedAt) / dwellDuration, 0), 1))
        guard progress >= 1 else { return nil }
        isLatched = true
        return VRControlActivation(target: hit.target, value: hit.value)
    }

    mutating func reset() {
        target = nil
        progress = 0
        startedAt = 0
        isLatched = false
    }
}

nonisolated struct HeadGestureDetector: Sendable {
    private var referencePitch: Float?
    private var armedDirection: Int?
    private var armedAt: TimeInterval?
    private var requiresNeutral = false
    private var lastTriggeredAt: TimeInterval = -.infinity

    let excursionRadians: Float
    let neutralBandRadians: Float
    let maximumGestureDuration: TimeInterval
    let cooldown: TimeInterval

    init(
        excursionRadians: Float = .pi / 22.5,
        neutralBandRadians: Float = .pi / 60,
        maximumGestureDuration: TimeInterval = 1.5,
        cooldown: TimeInterval = 2
    ) {
        self.excursionRadians = excursionRadians
        self.neutralBandRadians = neutralBandRadians
        self.maximumGestureDuration = maximumGestureDuration
        self.cooldown = cooldown
    }

    mutating func observe(pitch: Float, at time: TimeInterval) -> Bool {
        guard time - lastTriggeredAt >= cooldown else { return false }
        guard let referencePitch else {
            self.referencePitch = pitch
            return false
        }

        if let armedAt, time - armedAt > maximumGestureDuration {
            armedDirection = nil
            self.armedAt = nil
        }

        let offset = pitch - referencePitch
        if abs(offset) <= neutralBandRadians {
            if requiresNeutral {
                requiresNeutral = false
            }
            if armedDirection == nil {
                self.referencePitch = pitch
            }
            return false
        }

        guard !requiresNeutral, abs(offset) >= excursionRadians else { return false }
        let direction = offset > 0 ? 1 : -1
        guard let armedDirection else {
            self.armedDirection = direction
            armedAt = time
            return false
        }
        guard direction != armedDirection else { return false }

        self.armedDirection = nil
        armedAt = nil
        requiresNeutral = true
        lastTriggeredAt = time
        return true
    }

    mutating func reset() {
        referencePitch = nil
        armedDirection = nil
        armedAt = nil
        requiresNeutral = false
        lastTriggeredAt = -.infinity
    }
}
