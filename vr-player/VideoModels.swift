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
        case .mono: "单幅"
        case .sideBySide: "SBS"
        case .topBottom: "上下"
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
        case .preparing: "正在准备"
        case .buffering: "正在缓冲"
        case .playing: "正在播放"
        case .paused: "已暂停"
        case .ended: "播放结束"
        case .failed: "无法播放"
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
final class VideoFolder: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var parent: VideoFolder?
    @Relationship(deleteRule: .cascade, inverse: \VideoFolder.parent)
    var children: [VideoFolder]
    @Relationship(deleteRule: .cascade, inverse: \PlaylistItem.folder)
    var items: [PlaylistItem]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        parent: VideoFolder? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parent = parent
        children = []
        items = []
    }
}

@Model
final class PlaylistItem: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var bookmarkData: Data
    var sourceDisplayPath: String
    var sourceIdentity: String?
    var sourceKindRawValue: String
    var addedAt: Date
    var lastPlayedAt: Date?
    var lastPosition: Double
    var duration: Double
    var projectionRawValue: String
    var stereoLayoutRawValue: String
    var videoCodecRawValue: String?
    var mediaSummary: String?
    var systemPlayable: Bool?
    var hevcProbeStatusRawValue: String?
    var hevcProbeStatusCode: Int?
    var hevcProbeDetail: String?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var folder: VideoFolder?

    init(
        id: UUID = UUID(),
        name: String,
        bookmarkData: Data,
        sourceDisplayPath: String,
        sourceIdentity: String? = nil,
        sourceKind: MediaSourceKind,
        addedAt: Date = .now,
        lastPlayedAt: Date? = nil,
        lastPosition: Double = 0,
        duration: Double = 0,
        projection: VRProjection = .sphere360,
        stereoLayout: StereoLayout = .mono,
        mediaInspection: MediaInspection? = nil,
        thumbnailData: Data? = nil,
        folder: VideoFolder? = nil
    ) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.sourceDisplayPath = sourceDisplayPath
        self.sourceIdentity = sourceIdentity
        sourceKindRawValue = sourceKind.rawValue
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.lastPosition = lastPosition
        self.duration = duration
        projectionRawValue = projection.rawValue
        stereoLayoutRawValue = stereoLayout.rawValue
        videoCodecRawValue = mediaInspection?.videoCodec.rawValue
        mediaSummary = mediaInspection?.summary
        systemPlayable = mediaInspection?.isSystemPlayable
        hevcProbeStatusRawValue = mediaInspection?.hevcHardwareProbe?.status.rawValue
        hevcProbeStatusCode = mediaInspection?.hevcHardwareProbe?.statusCode.map(Int.init)
        hevcProbeDetail = mediaInspection?.hevcHardwareProbe?.detail
        self.thumbnailData = thumbnailData
        self.folder = folder
    }

    func resetForReimport(
        name: String,
        bookmarkData: Data,
        sourceDisplayPath: String,
        sourceIdentity: String,
        sourceKind: MediaSourceKind,
        mediaInspection: MediaInspection,
        thumbnailData: Data?,
        folder: VideoFolder?
    ) {
        self.name = name
        self.bookmarkData = bookmarkData
        self.sourceDisplayPath = sourceDisplayPath
        self.sourceIdentity = sourceIdentity
        self.sourceKind = sourceKind
        addedAt = .now
        lastPlayedAt = nil
        lastPosition = 0
        duration = 0
        projection = .sphere360
        stereoLayout = .mono
        videoCodecRawValue = mediaInspection.videoCodec.rawValue
        mediaSummary = mediaInspection.summary
        systemPlayable = mediaInspection.isSystemPlayable
        hevcProbeStatusRawValue = mediaInspection.hevcHardwareProbe?.status.rawValue
        hevcProbeStatusCode = mediaInspection.hevcHardwareProbe?.statusCode.map(Int.init)
        hevcProbeDetail = mediaInspection.hevcHardwareProbe?.detail
        self.thumbnailData = thumbnailData
        self.folder = folder
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

    var videoCodec: SupportedVideoCodec? {
        guard let videoCodecRawValue else { return nil }
        return SupportedVideoCodec(rawValue: videoCodecRawValue)
    }

    var storedHEVCProbeResult: HEVCHardwareProbeResult? {
        guard let rawValue = hevcProbeStatusRawValue,
              let status = HEVCHardwareProbeResult.Status(rawValue: rawValue)
        else { return nil }
        return HEVCHardwareProbeResult(
            status: status,
            statusCode: hevcProbeStatusCode.map(Int32.init),
            detail: hevcProbeDetail ?? "未记录硬件解码器的详细信息。"
        )
    }
}
