@preconcurrency import AVFoundation
import CoreVideo
import Foundation

struct VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let itemTimeForDisplay: CMTime
}

final class VideoFrameProvider: @unchecked Sendable {
    private let output: AVPlayerItemVideoOutput

    init(output: AVPlayerItemVideoOutput) {
        self.output = output
    }

    func copyFrame(forPresentationHostTime hostTime: CFTimeInterval) -> VideoFrame? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        var itemTimeForDisplay = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &itemTimeForDisplay
        ) else { return nil }
        return VideoFrame(pixelBuffer: pixelBuffer, itemTimeForDisplay: itemTimeForDisplay)
    }
}
