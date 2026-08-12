import Foundation
import Observation

@MainActor
@Observable
final class PlayerSession {
    private(set) var phase: PlaybackPhase = .preparing
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var currentItem: PlaylistItem
    private(set) var frameProvider: any VideoFrameProviding
    private(set) var repeatsCurrentItem: Bool
    private(set) var playbackRate: Double
    private(set) var isUsingHEVCFallback = false
    var bufferedFraction: Double = 0

    @ObservationIgnored private var engine: any PlaybackEngine
    @ObservationIgnored private var hasRestoredPosition = false
    @ObservationIgnored private var playbackRequested = true
    @ObservationIgnored private var fallbackAttempted = false
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    @ObservationIgnored private var isShutdown = false

    init(
        item: PlaylistItem,
        repeatsCurrentItem: Bool = false,
        playbackRate: Double = 1
    ) throws {
        currentItem = item
        self.repeatsCurrentItem = repeatsCurrentItem
        self.playbackRate = playbackRate
        let engine = try AVPlayerPlaybackEngine(item: item)
        self.engine = engine
        frameProvider = engine.frameProvider
        configure(engine)
        engine.play(rate: playbackRate)
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        fallbackTask?.cancel()
        fallbackTask = nil
        engine.shutdown()
    }

    var isPlaying: Bool { playbackRequested }

    func play() {
        playbackRequested = true
        if phase == .ended {
            position = 0
            currentItem.lastPosition = 0
            phase = PlaybackStateReducer.reduce(phase, event: .prepare)
            engine.seek(to: 0)
        }
        engine.play(rate: playbackRate)
    }

    func pause() {
        playbackRequested = false
        engine.pause()
        phase = PlaybackStateReducer.reduce(phase, event: .pause)
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
        engine.seek(to: target)
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
        if playbackRequested {
            engine.play(rate: playbackRate)
        }
    }

    private func configure(_ engine: any PlaybackEngine) {
        engine.onPhase = { [weak self, weak engine] newPhase in
            guard let self, let engine, self.engine === engine, !isShutdown else { return }
            phase = newPhase
            if case .failed = newPhase {
                playbackRequested = false
            }
        }
        engine.onPosition = { [weak self, weak engine] newPosition, newDuration in
            guard let self, let engine, self.engine === engine, !isShutdown else { return }
            if newDuration > 0 {
                duration = newDuration
                currentItem.duration = newDuration
            }
            position = max(newPosition, 0)
            currentItem.lastPosition = position
            currentItem.lastPlayedAt = .now
            restorePositionIfNeeded()
        }
        engine.onBufferedFraction = { [weak self, weak engine] fraction in
            guard let self, let engine, self.engine === engine, !isShutdown else { return }
            bufferedFraction = min(max(fraction, 0), 1)
        }
        engine.onEnded = { [weak self, weak engine] in
            guard let self, let engine, self.engine === engine, !isShutdown else { return }
            switch PlaybackControl.endAction(repeatsCurrentItem: repeatsCurrentItem) {
            case .finish:
                playbackRequested = false
                phase = PlaybackStateReducer.reduce(phase, event: .finish)
                currentItem.lastPosition = 0
            case .repeatCurrent:
                position = 0
                currentItem.lastPosition = 0
                phase = PlaybackStateReducer.reduce(phase, event: .prepare)
                engine.seek(to: 0)
                engine.play(rate: playbackRate)
            }
        }
        if let avEngine = engine as? AVPlayerPlaybackEngine {
            avEngine.onFallbackRequested = { [weak self, weak avEngine] reason in
                guard let self, let avEngine, self.engine === avEngine else { return }
                requestHEVCFallback(reason: reason)
            }
        }
    }

    private func restorePositionIfNeeded() {
        guard !hasRestoredPosition else { return }
        hasRestoredPosition = true
        let saved = currentItem.lastPosition
        if saved > 2, duration == 0 || saved < duration - 5 {
            position = saved
            engine.seek(to: saved)
        }
    }

    private func requestHEVCFallback(reason: String) {
        guard !fallbackAttempted, !isShutdown else { return }
        fallbackAttempted = true
        guard currentItem.videoCodec != .h264 else {
            playbackRequested = false
            phase = .failed(reason)
            return
        }

        phase = .buffering
        let fallbackStartPosition = position
        let shouldResume = playbackRequested
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fallback = try await HEVCVideoToolboxPlaybackEngine.make(item: currentItem)
                try Task.checkCancellation()
                guard !isShutdown else {
                    fallback.shutdown()
                    return
                }
                engine.shutdown()
                engine = fallback
                frameProvider = fallback.frameProvider
                isUsingHEVCFallback = true
                bufferedFraction = 0
                configure(fallback)
                fallback.seek(to: fallbackStartPosition)
                if shouldResume {
                    fallback.play(rate: playbackRate)
                } else {
                    fallback.pause()
                }
            } catch is CancellationError {
                return
            } catch {
                playbackRequested = false
                let probe = currentItem.storedHEVCProbeResult?.detail
                phase = .failed(
                    [reason, probe, "HEVC 备用播放失败：\(error.localizedDescription)"]
                        .compactMap { $0 }
                        .joined(separator: "\n")
                )
            }
        }
    }
}
