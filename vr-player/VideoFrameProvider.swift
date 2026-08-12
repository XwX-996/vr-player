@preconcurrency import AVFoundation
import CoreVideo
import Foundation

nonisolated struct VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let itemTimeForDisplay: CMTime
}

protocol VideoFrameProviding: AnyObject, Sendable {
    var hasDeliveredFrame: Bool { get }
    func copyFrame(forPresentationHostTime hostTime: CFTimeInterval) -> VideoFrame?
    func reportRenderFailure(_ message: String)
}

final class VideoFrameProvider: VideoFrameProviding, @unchecked Sendable {
    private let output: AVPlayerItemVideoOutput
    private let stateLock = NSLock()
    private var deliveredFrame = false
    private var reportedFailure = false
    private let firstFrameHandler: @Sendable () -> Void
    private let failureHandler: @Sendable (String) -> Void

    init(
        output: AVPlayerItemVideoOutput,
        firstFrameHandler: @escaping @Sendable () -> Void = {},
        failureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.output = output
        self.firstFrameHandler = firstFrameHandler
        self.failureHandler = failureHandler
    }

    var hasDeliveredFrame: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return deliveredFrame
    }

    func copyFrame(forPresentationHostTime hostTime: CFTimeInterval) -> VideoFrame? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        var itemTimeForDisplay = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &itemTimeForDisplay
        ) else { return nil }
        let isFirstFrame: Bool
        stateLock.lock()
        isFirstFrame = !deliveredFrame
        deliveredFrame = true
        stateLock.unlock()
        if isFirstFrame {
            firstFrameHandler()
        }
        return VideoFrame(pixelBuffer: pixelBuffer, itemTimeForDisplay: itemTimeForDisplay)
    }

    func reportRenderFailure(_ message: String) {
        stateLock.lock()
        let shouldReport = !reportedFailure
        reportedFailure = true
        stateLock.unlock()
        if shouldReport {
            failureHandler(message)
        }
    }
}
