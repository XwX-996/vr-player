@preconcurrency import AVFoundation
import Foundation
import UIKit

nonisolated enum VideoThumbnailGenerator {
    static let maximumSize = CGSize(width: 304, height: 192)
    static let jpegCompressionQuality = 0.8

    static func generate(from url: URL) async -> Data? {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let requestedTime = thumbnailTime(for: duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = maximumSize
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            let image = try await generator.image(at: requestedTime).image
            return UIImage(cgImage: image).jpegData(
                compressionQuality: jpegCompressionQuality
            )
        } catch {
            return nil
        }
    }

    static func thumbnailTime(for duration: CMTime) -> CMTime {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return .zero }
        return CMTime(
            seconds: seconds / 2,
            preferredTimescale: 600
        )
    }
}
