import Foundation
import SwiftData

nonisolated enum VRProjection: String, CaseIterable, Codable, Identifiable, Sendable {
    case sphere360
    case hemisphere180

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sphere360: "360\u{00b0}"
        case .hemisphere180: "180\u{00b0}"
        }
    }
}

nonisolated enum StereoLayout: String, CaseIterable, Codable, Identifiable, Sendable {
    case mono
    case sideBySide
    case topBottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mono: "Mono"
        case .sideBySide: "SBS"
        case .topBottom: "Top/Bottom"
        }
    }
}

nonisolated enum MediaSourceKind: String, Codable, Sendable {
    case local
    case remote
}

nonisolated enum PlaybackPhase: Equatable, Sendable {
    case preparing
    case buffering
    case playing
    case paused
    case ended
    case failed(String)

    var title: String {
        switch self {
        case .preparing: "Preparing"
        case .buffering: "Buffering"
        case .playing: "Playing"
        case .paused: "Paused"
        case .ended: "Finished"
        case .failed: "Unavailable"
        }
    }
}

nonisolated enum PlaybackPhaseEvent: Equatable, Sendable {
    case prepare
    case waitForData
    case startPlaying
    case pause
    case finish
    case fail(String)
}

nonisolated enum PlaybackStateReducer {
    static func reduce(_ current: PlaybackPhase, event: PlaybackPhaseEvent) -> PlaybackPhase {
        switch event {
        case .prepare:
            return .preparing
        case .waitForData:
            return .buffering
        case .startPlaying:
            return .playing
        case .pause:
            switch current {
            case .ended, .failed:
                return current
            default:
                return .paused
            }
        case .finish:
            return .ended
        case .fail(let message):
            return .failed(message)
        }
    }
}

nonisolated enum PlaybackCommand: Equatable, Sendable {
    case pause
    case play
    case restart
}

nonisolated enum PlaybackEndAction: Equatable, Sendable {
    case finish
    case repeatCurrent
}

nonisolated enum PlaybackControl {
    static func toggleCommand(phase: PlaybackPhase, playbackRequested: Bool) -> PlaybackCommand {
        if playbackRequested {
            return .pause
        }
        return phase == .ended ? .restart : .play
    }

    static func endAction(repeatsCurrentItem: Bool) -> PlaybackEndAction {
        repeatsCurrentItem ? .repeatCurrent : .finish
    }
}

@Model
final class PlaylistItem: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var bookmarkData: Data
    var sourceDisplayPath: String
    var sourceKindRawValue: String
    var addedAt: Date
    var lastPlayedAt: Date?
    var lastPosition: Double
    var duration: Double
    var projectionRawValue: String
    var stereoLayoutRawValue: String
    var cacheIndexData: Data?
    var cacheContentLength: Int64?
    var cacheSourceModificationDate: Date?
    var cacheUpdatedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        bookmarkData: Data,
        sourceDisplayPath: String,
        sourceKind: MediaSourceKind,
        addedAt: Date = .now,
        lastPlayedAt: Date? = nil,
        lastPosition: Double = 0,
        duration: Double = 0,
        projection: VRProjection = .sphere360,
        stereoLayout: StereoLayout = .mono,
        cacheIndexData: Data? = nil,
        cacheContentLength: Int64? = nil,
        cacheSourceModificationDate: Date? = nil,
        cacheUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.sourceDisplayPath = sourceDisplayPath
        sourceKindRawValue = sourceKind.rawValue
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.lastPosition = lastPosition
        self.duration = duration
        projectionRawValue = projection.rawValue
        stereoLayoutRawValue = stereoLayout.rawValue
        self.cacheIndexData = cacheIndexData
        self.cacheContentLength = cacheContentLength
        self.cacheSourceModificationDate = cacheSourceModificationDate
        self.cacheUpdatedAt = cacheUpdatedAt
    }

    var sourceKind: MediaSourceKind {
        get { MediaSourceKind(rawValue: sourceKindRawValue) ?? .local }
        set { sourceKindRawValue = newValue.rawValue }
    }

    var projection: VRProjection {
        get { VRProjection(rawValue: projectionRawValue) ?? .sphere360 }
        set { projectionRawValue = newValue.rawValue }
    }

    var stereoLayout: StereoLayout {
        get { StereoLayout(rawValue: stereoLayoutRawValue) ?? .mono }
        set { stereoLayoutRawValue = newValue.rawValue }
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(lastPosition / duration, 0), 1)
    }
}
