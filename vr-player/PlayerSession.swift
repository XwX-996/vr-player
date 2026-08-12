@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Observation

@MainActor
@Observable
final class PlayerSession {
    private(set) var phase: PlaybackPhase = .preparing
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var currentItem: PlaylistItem
    private(set) var frameProvider: VideoFrameProvider
    private(set) var repeatsCurrentItem: Bool
    private(set) var playbackRate: Double
    var bufferedFraction: Double = 0

    @ObservationIgnored private var resource: PlayableAssetResource
    @ObservationIgnored private var playerItem: AVPlayerItem
    @ObservationIgnored private let videoOutput: AVPlayerItemVideoOutput
    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadedRangesObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var hasRestoredPosition = false
    @ObservationIgnored private var playbackRequested = true

    init(
        item: PlaylistItem,
        repeatsCurrentItem: Bool = false,
        playbackRate: Double = 1
    ) throws {
        currentItem = item
        self.repeatsCurrentItem = repeatsCurrentItem
        self.playbackRate = playbackRate
        resource = try PlayableAssetResource(item: item)
        playerItem = AVPlayerItem(asset: resource.asset)
        videoOutput = VideoOutputFactory.makeVideoOutput()
        playerItem.add(videoOutput)
        frameProvider = VideoFrameProvider(output: videoOutput)
        player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        playerItem.preferredForwardBufferDuration = 20
        configureObservers()
    }

    func shutdown() {
        player.pause()
        persistState()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation = nil
        timeControlObservation = nil
        loadedRangesObservation = nil
    }

    var isPlaying: Bool { playbackRequested }

    func persistState() {
        resource.persistCacheIndex(to: currentItem)
    }

    func play() {
        playbackRequested = true
        guard phase == .ended else {
            resumePlayback()
            return
        }

        position = 0
        currentItem.lastPosition = 0
        phase = PlaybackStateReducer.reduce(phase, event: .prepare)
        player.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished, self.playbackRequested else { return }
                self.resumePlayback()
            }
        }
    }

    func pause() {
        playbackRequested = false
        player.pause()
    }

    func togglePlayback() {
        switch PlaybackControl.toggleCommand(phase: phase, playbackRequested: playbackRequested) {
        case .pause:
            pause()
        case .play, .restart:
            play()
        }
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(seconds, 0), duration)
        position = target
        currentItem.lastPosition = target
        currentItem.lastPlayedAt = .now
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func setRepeatsCurrentItem(_ repeats: Bool) {
        repeatsCurrentItem = repeats
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = [0.5, 0.75, 1, 1.25, 1.5, 2].min(by: {
            abs($0 - rate) < abs($1 - rate)
        }) ?? 1
        if playbackRequested, playerItem.status == .readyToPlay {
            resumePlayback()
        }
    }

    private func configureObservers() {
        statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let loadedDuration = item.duration.seconds
                    if loadedDuration.isFinite {
                        duration = loadedDuration
                        currentItem.duration = loadedDuration
                    }
                    restorePositionIfNeeded()
                    if playbackRequested {
                        resumePlayback()
                    }
                case .failed:
                    playbackRequested = false
                    phase = PlaybackStateReducer.reduce(
                        phase,
                        event: .fail(item.error?.localizedDescription ?? "The video could not be opened.")
                    )
                default:
                    phase = PlaybackStateReducer.reduce(phase, event: .prepare)
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    phase = PlaybackStateReducer.reduce(phase, event: .startPlaying)
                case .waitingToPlayAtSpecifiedRate:
                    phase = PlaybackStateReducer.reduce(phase, event: .waitForData)
                case .paused:
                    phase = PlaybackStateReducer.reduce(phase, event: .pause)
                @unknown default:
                    phase = PlaybackStateReducer.reduce(phase, event: .pause)
                }
            }
        }

        loadedRangesObservation = playerItem.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let range = item.loadedTimeRanges.first?.timeRangeValue,
                      duration > 0
                else { return }
                bufferedFraction = min(max(range.end.seconds / duration, 0), 1)
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.position = max(seconds, 0)
                self.currentItem.lastPosition = self.position
                self.currentItem.lastPlayedAt = .now
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch PlaybackControl.endAction(repeatsCurrentItem: self.repeatsCurrentItem) {
                case .finish:
                    self.playbackRequested = false
                    self.phase = PlaybackStateReducer.reduce(self.phase, event: .finish)
                    self.currentItem.lastPosition = 0
                case .repeatCurrent:
                    self.position = 0
                    self.currentItem.lastPosition = 0
                    self.phase = PlaybackStateReducer.reduce(self.phase, event: .prepare)
                    self.player.seek(
                        to: .zero,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    ) { [weak self] finished in
                        Task { @MainActor [weak self] in
                            guard let self, finished, self.playbackRequested else { return }
                            self.resumePlayback()
                        }
                    }
                }
            }
        }
    }

    private func resumePlayback() {
        player.playImmediately(atRate: Float(playbackRate))
    }

    private func restorePositionIfNeeded() {
        guard !hasRestoredPosition else { return }
        hasRestoredPosition = true
        let saved = currentItem.lastPosition
        if saved > 2, duration == 0 || saved < duration - 5 {
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
        }
    }
}
