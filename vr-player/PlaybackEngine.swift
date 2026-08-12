@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

private nonisolated enum PlaybackDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cxc.vr-player",
        category: "Playback"
    )
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var frameProvider: any VideoFrameProviding { get }
    var onPhase: ((PlaybackPhase) -> Void)? { get set }
    var onPosition: ((Double, Double) -> Void)? { get set }
    var onBufferedFraction: ((Double) -> Void)? { get set }
    var onEnded: (() -> Void)? { get set }

    func play(rate: Double)
    func pause()
    func seek(to seconds: Double)
    func shutdown()
}

private nonisolated final class PlaybackCallbackRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var firstFrameHandler: @Sendable () -> Void = {}
    private var failureHandler: @Sendable (String) -> Void = { _ in }

    func configure(
        firstFrameHandler: @escaping @Sendable () -> Void,
        failureHandler: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        self.firstFrameHandler = firstFrameHandler
        self.failureHandler = failureHandler
        lock.unlock()
    }

    func didDeliverFirstFrame() {
        lock.lock()
        let handler = firstFrameHandler
        lock.unlock()
        handler()
    }

    func didFail(_ message: String) {
        lock.lock()
        let handler = failureHandler
        lock.unlock()
        handler(message)
    }
}

@MainActor
final class AVPlayerPlaybackEngine: PlaybackEngine {
    let frameProvider: any VideoFrameProviding
    var onPhase: ((PlaybackPhase) -> Void)?
    var onPosition: ((Double, Double) -> Void)?
    var onBufferedFraction: ((Double) -> Void)?
    var onEnded: (() -> Void)?
    var onFallbackRequested: ((String) -> Void)?

    private let resource: PlayableAssetResource
    private let playerItem: AVPlayerItem
    private let videoOutput: AVPlayerItemVideoOutput
    private let player: AVPlayer
    private let firstFrameTimeout: TimeInterval
    private let mediaSummary: String?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var loadedRangesObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeoutTask: Task<Void, Never>?
    private var requestedRate: Double = 1
    private var isShutdown = false
    private var hasRequestedFallback = false
    private var firstFrameStartedAt: TimeInterval?

    init(item: PlaylistItem) throws {
        resource = try PlayableAssetResource(item: item)
        playerItem = AVPlayerItem(asset: resource.asset)
        videoOutput = VideoOutputFactory.makeVideoOutput()
        videoOutput.suppressesPlayerRendering = true
        playerItem.add(videoOutput)
        player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = item.sourceKind != .remote
        playerItem.preferredForwardBufferDuration = 20
        firstFrameTimeout = item.sourceKind == .remote ? 30 : 12
        mediaSummary = item.mediaSummary

        let callbackRelay = PlaybackCallbackRelay()
        frameProvider = VideoFrameProvider(
            output: videoOutput,
            firstFrameHandler: { callbackRelay.didDeliverFirstFrame() },
            failureHandler: { message in callbackRelay.didFail(message) }
        )
        callbackRelay.configure(
            firstFrameHandler: { [weak self] in
                Task { @MainActor [weak self] in self?.didDeliverFirstFrame() }
            },
            failureHandler: { [weak self] message in
                Task { @MainActor [weak self] in self?.requestFallback(reason: message) }
            }
        )
        configureObservers()
    }

    func play(rate: Double) {
        requestedRate = rate
        player.playImmediately(atRate: Float(rate))
        armFirstFrameTimeoutIfNeeded()
    }

    func pause() {
        player.pause()
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        )
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        timeoutTask?.cancel()
        timeoutTask = nil
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
        statusObservation = nil
        timeControlObservation = nil
        loadedRangesObservation = nil
    }

    private func configureObservers() {
        statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, !isShutdown else { return }
                switch item.status {
                case .readyToPlay:
                    PlaybackDiagnostics.logger.info("AVPlayer item ready")
                    let duration = item.duration.seconds
                    onPosition?(max(player.currentTime().seconds, 0), duration.isFinite ? duration : 0)
                case .failed:
                    PlaybackDiagnostics.logger.error("AVPlayer item failed")
                    requestFallback(reason: diagnosticMessage(error: item.error))
                default:
                    onPhase?(.preparing)
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, !isShutdown else { return }
                switch player.timeControlStatus {
                case .playing:
                    PlaybackDiagnostics.logger.info("AVPlayer started playing")
                    onPhase?(.playing)
                case .waitingToPlayAtSpecifiedRate:
                    let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
                    PlaybackDiagnostics.logger.info("AVPlayer waiting: \(reason, privacy: .public)")
                    onPhase?(.buffering)
                case .paused:
                    onPhase?(.paused)
                @unknown default:
                    onPhase?(.paused)
                }
            }
        }

        loadedRangesObservation = playerItem.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let range = item.loadedTimeRanges.first?.timeRangeValue,
                      item.duration.seconds.isFinite,
                      item.duration.seconds > 0
                else { return }
                onBufferedFraction?(min(max(range.end.seconds / item.duration.seconds, 0), 1))
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isShutdown, time.seconds.isFinite else { return }
                let duration = self.playerItem.duration.seconds
                self.onPosition?(max(time.seconds, 0), duration.isFinite ? duration : 0)
            }
        }

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        })
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requestFallback(reason: self.diagnosticMessage(error: self.playerItem.error))
            }
        })
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let message = self.diagnosticMessage(error: self.playerItem.error)
                PlaybackDiagnostics.logger.error("AVPlayer error log: \(message, privacy: .public)")
                if self.playerItem.status == .failed {
                    self.requestFallback(reason: message)
                }
            }
        })
    }

    private func armFirstFrameTimeoutIfNeeded() {
        guard !frameProvider.hasDeliveredFrame, timeoutTask == nil else { return }
        firstFrameStartedAt = ProcessInfo.processInfo.systemUptime
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(firstFrameTimeout))
            } catch {
                return
            }
            guard !frameProvider.hasDeliveredFrame, !isShutdown else { return }
            requestFallback(reason: "等待 \(Int(firstFrameTimeout)) 秒后仍未收到解码画面。")
        }
    }

    private func didDeliverFirstFrame() {
        if let firstFrameStartedAt {
            let elapsed = ProcessInfo.processInfo.systemUptime - firstFrameStartedAt
            PlaybackDiagnostics.logger.info("AVPlayer first frame in \(elapsed, format: .fixed(precision: 3)) seconds")
        }
        firstFrameStartedAt = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func requestFallback(reason: String) {
        guard !hasRequestedFallback, !isShutdown else { return }
        hasRequestedFallback = true
        timeoutTask?.cancel()
        timeoutTask = nil
        player.pause()
        PlaybackDiagnostics.logger.error("Requesting HEVC fallback: \(reason, privacy: .public)")
        onFallbackRequested?(reason)
    }

    private func diagnosticMessage(error: Error?) -> String {
        var components: [String] = []
        if let error {
            components.append(error.localizedDescription)
        }
        if let event = playerItem.errorLog()?.events.last {
            let parts = [event.errorDomain, String(event.errorStatusCode), event.errorComment]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                components.append(parts.joined(separator: ": "))
            }
        }
        if let reason = player.reasonForWaitingToPlay {
            components.append("Waiting reason: \(reason.rawValue)")
        }
        if let event = playerItem.accessLog()?.events.last {
            components.append("Dropped frames: \(event.numberOfDroppedVideoFrames)")
        }
        if let mediaSummary {
            components.append("Source: \(mediaSummary)")
        }
        return components.isEmpty ? "无法打开视频。" : components.joined(separator: "\n")
    }
}

nonisolated final class BoundedVideoFrameQueue: VideoFrameProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [VideoFrame] = []
    private var deliveredFrame = false
    private var reportedFailure = false
    private var droppedFrames = 0
    private var itemTimeProvider: @Sendable () -> CMTime = { .zero }
    private var failureHandler: @Sendable (String) -> Void = { _ in }

    init(capacity: Int = 3) {
        self.capacity = max(capacity, 1)
    }

    var hasDeliveredFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deliveredFrame
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedFrames
    }

    func configure(
        itemTimeProvider: @escaping @Sendable () -> CMTime,
        failureHandler: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        self.itemTimeProvider = itemTimeProvider
        self.failureHandler = failureHandler
        lock.unlock()
    }

    func enqueue(_ frame: VideoFrame) {
        lock.lock()
        frames.append(frame)
        frames.sort { CMTimeCompare($0.itemTimeForDisplay, $1.itemTimeForDisplay) < 0 }
        if frames.count > capacity {
            let overflow = frames.count - capacity
            frames.removeFirst(overflow)
            droppedFrames += overflow
        }
        lock.unlock()
    }

    func copyFrame(forPresentationHostTime hostTime: CFTimeInterval) -> VideoFrame? {
        lock.lock()
        let provider = itemTimeProvider
        lock.unlock()
        let currentTime = provider()

        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        var selectedIndex: Int?
        for index in frames.indices where CMTimeCompare(frames[index].itemTimeForDisplay, currentTime) <= 0 {
            selectedIndex = index
        }
        guard let selectedIndex else { return nil }
        let selected = frames[selectedIndex]
        frames.removeFirst(selectedIndex + 1)
        droppedFrames += selectedIndex
        deliveredFrame = true
        return selected
    }

    func flush() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func reportRenderFailure(_ message: String) {
        lock.lock()
        let shouldReport = !reportedFailure
        reportedFailure = true
        let handler = failureHandler
        lock.unlock()
        if shouldReport { handler(message) }
    }
}

nonisolated final class PlaybackGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UUID?
    private var firstFrameGeneration: UUID?

    func activate() -> UUID {
        let generation = UUID()
        lock.lock()
        activeGeneration = generation
        firstFrameGeneration = nil
        lock.unlock()
        return generation
    }

    func cancel() {
        lock.lock()
        activeGeneration = nil
        firstFrameGeneration = nil
        lock.unlock()
    }

    func isActive(_ generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    func claimFirstFrame(for generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation,
              firstFrameGeneration != generation
        else { return false }
        firstFrameGeneration = generation
        return true
    }
}

private nonisolated final class HEVCDecodeContext: @unchecked Sendable {
    let reader: AVAssetReader
    let videoOutput: AVAssetReaderTrackOutput
    let audioOutput: AVAssetReaderTrackOutput?
    let audioRenderer: AVSampleBufferAudioRenderer?
    let presentationStartTime: CMTime

    init(
        reader: AVAssetReader,
        videoOutput: AVAssetReaderTrackOutput,
        audioOutput: AVAssetReaderTrackOutput?,
        audioRenderer: AVSampleBufferAudioRenderer?,
        presentationStartTime: CMTime
    ) {
        self.reader = reader
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.audioRenderer = audioRenderer
        self.presentationStartTime = presentationStartTime
    }
}

@MainActor
final class HEVCVideoToolboxPlaybackEngine: PlaybackEngine {
    let frameProvider: any VideoFrameProviding
    var onPhase: ((PlaybackPhase) -> Void)?
    var onPosition: ((Double, Double) -> Void)?
    var onBufferedFraction: ((Double) -> Void)?
    var onEnded: (() -> Void)?

    private let resource: PlayableAssetResource
    private let asset: AVAsset
    private let videoTrack: AVAssetTrack
    private let audioTrack: AVAssetTrack?
    private let queueProvider: BoundedVideoFrameQueue
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer: AVSampleBufferAudioRenderer?
    private let decodeQueue = DispatchQueue(label: "cxc.vr-player.hevc-decode", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "cxc.vr-player.hevc-audio", qos: .userInteractive)
    private var decodeContext: HEVCDecodeContext?
    private var timeObserver: Any?
    private let generationGate = PlaybackGenerationGate()
    private var requestedRate: Double = 1
    private var playbackRequested = false
    private var isShutdown = false
    private var firstFrameStartedAt: TimeInterval?
    private let duration: Double
    private let mediaSummary: String?
    private let hardwareProbeDetail: String?

    static func make(item: PlaylistItem) async throws -> HEVCVideoToolboxPlaybackEngine {
        let resource = try PlayableAssetResource(item: item)
        let videoTracks = try await resource.asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MediaImportValidationError.missingVideoTrack
        }
        let descriptions = try await videoTrack.load(.formatDescriptions)
        guard !descriptions.isEmpty,
              descriptions.allSatisfy({
                  MediaImportValidator.videoCodec(
                      for: CMFormatDescriptionGetMediaSubType($0)
                  ) == .hevc
              })
        else {
            throw PlaybackEngineError.notHEVC
        }
        let audioTrack = try await resource.asset.loadTracks(withMediaType: .audio).first
        let duration = try await resource.asset.load(.duration).seconds
        return HEVCVideoToolboxPlaybackEngine(
            resource: resource,
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            duration: duration.isFinite ? duration : 0,
            mediaSummary: item.mediaSummary,
            hardwareProbeDetail: item.storedHEVCProbeResult?.detail
        )
    }

    private init(
        resource: PlayableAssetResource,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        duration: Double,
        mediaSummary: String?,
        hardwareProbeDetail: String?
    ) {
        self.resource = resource
        asset = resource.asset
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.duration = duration
        self.mediaSummary = mediaSummary
        self.hardwareProbeDetail = hardwareProbeDetail
        let queue = BoundedVideoFrameQueue(capacity: 3)
        queueProvider = queue
        frameProvider = queue

        if audioTrack != nil {
            let renderer = AVSampleBufferAudioRenderer()
            renderer.audioTimePitchAlgorithm = .timeDomain
            synchronizer.addRenderer(renderer)
            audioRenderer = renderer
        } else {
            audioRenderer = nil
        }
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = audioRenderer != nil
        queue.configure(
            itemTimeProvider: { [weak synchronizer] in
                synchronizer?.currentTime() ?? .zero
            },
            failureHandler: { [weak self] message in
                Task { @MainActor [weak self] in self?.fail(message) }
            }
        )
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isShutdown, time.seconds.isFinite else { return }
                self.onPosition?(max(time.seconds, 0), self.duration)
                if self.duration > 0, time.seconds >= self.duration - 0.05 {
                    self.playbackRequested = false
                    self.synchronizer.rate = 0
                    self.onEnded?()
                }
            }
        }
    }

    func play(rate: Double) {
        requestedRate = rate
        playbackRequested = true
        if decodeContext == nil {
            rebuildReader(at: max(synchronizer.currentTime().seconds, 0), startPlaying: true)
        } else {
            synchronizer.rate = Float(rate)
            onPhase?(.playing)
        }
    }

    func pause() {
        playbackRequested = false
        synchronizer.rate = 0
        onPhase?(.paused)
    }

    func seek(to seconds: Double) {
        rebuildReader(at: min(max(seconds, 0), duration), startPlaying: playbackRequested)
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        playbackRequested = false
        synchronizer.rate = 0
        generationGate.cancel()
        decodeContext?.reader.cancelReading()
        decodeContext = nil
        queueProvider.flush()
        audioRenderer?.stopRequestingMediaData()
        audioRenderer?.flush()
        if let timeObserver {
            synchronizer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        PlaybackDiagnostics.logger.info(
            "HEVC fallback stopped with \(self.queueProvider.droppedFrameCount) dropped frames"
        )
    }

    private func rebuildReader(at seconds: Double, startPlaying: Bool) {
        let newGeneration = generationGate.activate()
        synchronizer.rate = 0
        decodeContext?.reader.cancelReading()
        decodeContext = nil
        audioRenderer?.stopRequestingMediaData()
        audioRenderer?.flush()
        queueProvider.flush()
        firstFrameStartedAt = ProcessInfo.processInfo.systemUptime
        onPhase?(.preparing)
        onPosition?(seconds, duration)

        do {
            let presentationStartTime = CMTime(seconds: seconds, preferredTimescale: 600)
            let readerStartTime = seekPrerollStartTime(for: presentationStartTime)
            let reader = try AVAssetReader(asset: asset)
            if duration > 0 {
                reader.timeRange = CMTimeRange(
                    start: readerStartTime,
                    duration: CMTime(
                        seconds: max(duration - max(readerStartTime.seconds, 0), 0),
                        preferredTimescale: 600
                    )
                )
            }
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                fail("HEVC 备用播放无法读取压缩视频轨道。")
                return
            }
            reader.add(videoOutput)

            var audioOutput: AVAssetReaderTrackOutput?
            if let audioTrack, audioRenderer != nil {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    fail("HEVC 备用播放无法读取 AAC 音频轨道。")
                    return
                }
                reader.add(output)
                audioOutput = output
            }
            guard reader.startReading() else {
                fail(reader.error?.localizedDescription ?? "HEVC 备用播放无法开始读取文件。")
                return
            }
            let context = HEVCDecodeContext(
                reader: reader,
                videoOutput: videoOutput,
                audioOutput: audioOutput,
                audioRenderer: audioRenderer,
                presentationStartTime: presentationStartTime
            )
            decodeContext = context

            synchronizer.setRate(
                startPlaying ? Float(requestedRate) : 0,
                time: presentationStartTime
            )
            if audioOutput != nil, let audioRenderer {
                audioRenderer.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
                    self?.supplyAudio(context: context, generation: newGeneration)
                }
            }
            decodeQueue.async { [weak self] in
                self?.decodeVideo(context: context, generation: newGeneration)
            }
            if startPlaying {
                onPhase?(.buffering)
            } else {
                onPhase?(.paused)
            }
        } catch {
            fail("HEVC 备用播放无法打开文件：\(error.localizedDescription)")
        }
    }

    private func seekPrerollStartTime(for target: CMTime) -> CMTime {
        guard CMTimeCompare(target, .zero) > 0,
              let targetCursor = videoTrack.makeSampleCursor(presentationTimeStamp: target),
              let refreshCursor = targetCursor.copy() as? AVSampleCursor
        else { return target }

        let requiredSamples = targetCursor.samplesRequiredForDecoderRefresh
        if requiredSamples > 0 {
            _ = refreshCursor.stepInDecodeOrder(byCount: -Int64(requiredSamples))
        } else if !targetCursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
            for _ in 0..<600 {
                if refreshCursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { break }
                guard refreshCursor.stepInDecodeOrder(byCount: -1) == -1 else { break }
            }
        }

        let candidate = refreshCursor.presentationTimeStamp
        guard candidate.isValid,
              candidate.isNumeric,
              CMTimeCompare(candidate, .zero) >= 0,
              CMTimeCompare(candidate, target) < 0
        else { return target }
        return candidate
    }

    private nonisolated func decodeVideo(
        context: HEVCDecodeContext,
        generation: UUID
    ) {
        var decompressionSession: VTDecompressionSession?
        defer {
            if let decompressionSession {
                VTDecompressionSessionFinishDelayedFrames(decompressionSession)
                VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
                VTDecompressionSessionInvalidate(decompressionSession)
            }
        }

        while isCurrent(generation), let sample = context.videoOutput.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let formatDescription = CMSampleBufferGetFormatDescription(sample)
            else { continue }
            do {
                if let currentSession = decompressionSession,
                   !VTDecompressionSessionCanAcceptFormatDescription(
                    currentSession,
                    formatDescription: formatDescription
                   ) {
                    VTDecompressionSessionInvalidate(currentSession)
                    decompressionSession = nil
                }
                if decompressionSession == nil {
                    decompressionSession = try makeDecoderSession(for: formatDescription)
                }
                guard let session = decompressionSession else {
                    throw PlaybackEngineError.hardwareDecoderUnavailable(kVTInvalidSessionErr)
                }
                var infoFlags = VTDecodeInfoFlags()
                let status = VTDecompressionSessionDecodeFrame(
                    session,
                    sampleBuffer: sample,
                    flags: [],
                    infoFlagsOut: &infoFlags
                ) { [weak self] status, _, imageBuffer, presentationTime, _ in
                    guard status == noErr, let self, let imageBuffer, self.isCurrent(generation) else {
                        if status != noErr {
                            self?.reportDecodeFailure(status: status, generation: generation)
                        }
                        return
                    }
                    guard !presentationTime.isValid
                            || CMTimeCompare(presentationTime, context.presentationStartTime) >= 0
                    else { return }
                    queueProvider.enqueue(
                        VideoFrame(pixelBuffer: imageBuffer, itemTimeForDisplay: presentationTime)
                    )
                    if generationGate.claimFirstFrame(for: generation) {
                        Task { @MainActor [weak self] in
                            self?.didDeliverFirstFallbackFrame()
                        }
                    }
                }
                if status != noErr {
                    reportDecodeFailure(status: status, generation: generation)
                    return
                }
                while queueProvider.count >= 3, isCurrent(generation) {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            } catch {
                reportFailure(error.localizedDescription, generation: generation)
                return
            }
        }
        if isCurrent(generation), context.reader.status == .failed {
            reportFailure(
                context.reader.error?.localizedDescription ?? "HEVC 备用播放读取失败。",
                generation: generation
            )
        }
    }

    private nonisolated func makeDecoderSession(
        for formatDescription: CMFormatDescription
    ) throws -> VTDecompressionSession {
        let specification = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true,
        ] as CFDictionary
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: specification,
            imageBufferAttributes: attributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw PlaybackEngineError.hardwareDecoderUnavailable(status)
        }
        return session
    }

    private nonisolated func supplyAudio(
        context: HEVCDecodeContext,
        generation: UUID
    ) {
        guard let output = context.audioOutput,
              let renderer = context.audioRenderer
        else { return }
        guard isCurrent(generation) else { return }
        while renderer.isReadyForMoreMediaData, isCurrent(generation) {
            guard let sample = output.copyNextSampleBuffer() else {
                renderer.stopRequestingMediaData()
                return
            }
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
            if sampleTime.isValid,
               CMTimeCompare(sampleTime, context.presentationStartTime) < 0 {
                continue
            }
            renderer.enqueue(sample)
        }
        if renderer.status == .failed {
            reportFailure(
                renderer.error?.localizedDescription ?? "AAC 音频渲染失败。",
                generation: generation
            )
        }
    }

    private nonisolated func isCurrent(_ generation: UUID) -> Bool {
        generationGate.isActive(generation)
    }

    private nonisolated func reportDecodeFailure(status: OSStatus, generation: UUID) {
        reportFailure("The hardware HEVC decoder rejected a frame (OSStatus \(status)).", generation: generation)
    }

    private nonisolated func reportFailure(_ message: String, generation: UUID) {
        guard isCurrent(generation) else { return }
        Task { @MainActor [weak self] in self?.fail(message) }
    }

    private func didDeliverFirstFallbackFrame() {
        if let firstFrameStartedAt {
            let elapsed = ProcessInfo.processInfo.systemUptime - firstFrameStartedAt
            PlaybackDiagnostics.logger.info(
                "HEVC fallback first frame in \(elapsed, format: .fixed(precision: 3)) seconds"
            )
        }
        firstFrameStartedAt = nil
        if playbackRequested {
            onPhase?(.playing)
        }
    }

    private func fail(_ message: String) {
        guard !isShutdown else { return }
        playbackRequested = false
        synchronizer.rate = 0
        var details = message
        if let mediaSummary {
            details += "\nSource: \(mediaSummary)"
        }
        if let hardwareProbeDetail {
            details += "\nHardware probe: \(hardwareProbeDetail)"
        }
        details += "\nDropped frames: \(queueProvider.droppedFrameCount)"
        PlaybackDiagnostics.logger.error("HEVC fallback failed: \(details, privacy: .public)")
        generationGate.cancel()
        decodeContext?.reader.cancelReading()
        decodeContext = nil
        audioRenderer?.stopRequestingMediaData()
        audioRenderer?.flush()
        queueProvider.flush()
        onPhase?(.failed(details))
    }
}

private nonisolated enum PlaybackEngineError: LocalizedError {
    case notHEVC
    case hardwareDecoderUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notHEVC:
            "The source video track is not HEVC."
        case .hardwareDecoderUnavailable(let status):
            "This device could not create a hardware HEVC decoder for the source (OSStatus \(status))."
        }
    }
}
