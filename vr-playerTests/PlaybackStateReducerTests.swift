import AudioToolbox
import CoreMedia
import CoreVideo
import XCTest
@testable import vr_player

final class PlaybackStateReducerTests: XCTestCase {
    func testNormalPlaybackTransitions() {
        var phase: PlaybackPhase = .preparing
        phase = PlaybackStateReducer.reduce(phase, event: .waitForData)
        XCTAssertEqual(phase, .buffering)
        phase = PlaybackStateReducer.reduce(phase, event: .startPlaying)
        XCTAssertEqual(phase, .playing)
        phase = PlaybackStateReducer.reduce(phase, event: .pause)
        XCTAssertEqual(phase, .paused)
        phase = PlaybackStateReducer.reduce(phase, event: .finish)
        XCTAssertEqual(phase, .ended)
    }

    func testPauseDoesNotOverwriteTerminalState() {
        XCTAssertEqual(PlaybackStateReducer.reduce(.ended, event: .pause), .ended)
        XCTAssertEqual(
            PlaybackStateReducer.reduce(.failed("offline"), event: .pause),
            .failed("offline")
        )
    }

    func testPlaybackToggleUsesIntentDuringBufferingAndRestartsAtEnd() {
        XCTAssertEqual(
            PlaybackControl.toggleCommand(phase: .buffering, playbackRequested: true),
            .pause
        )
        XCTAssertEqual(
            PlaybackControl.toggleCommand(phase: .ended, playbackRequested: false),
            .restart
        )
        XCTAssertEqual(
            PlaybackControl.toggleCommand(phase: .paused, playbackRequested: false),
            .play
        )
    }
}

final class MediaImportValidatorTests: XCTestCase {
    func testRecognizesSupportedVideoSampleEntries() {
        XCTAssertEqual(MediaImportValidator.videoCodec(for: MediaImportValidator.fourCC("hvc1")), .hevc)
        XCTAssertEqual(MediaImportValidator.videoCodec(for: MediaImportValidator.fourCC("hev1")), .hevc)
        XCTAssertEqual(MediaImportValidator.videoCodec(for: kCMVideoCodecType_HEVC), .hevc)
        XCTAssertEqual(MediaImportValidator.videoCodec(for: kCMVideoCodecType_H264), .h264)
        XCTAssertNil(MediaImportValidator.videoCodec(for: MediaImportValidator.fourCC("vp09")))
    }

    func testRejectsHDRAndUnsupportedAudio() {
        XCTAssertThrowsError(
            try MediaImportValidator.validateMediaPolicy(
                videoCodec: .hevc,
                isHDR: true,
                audioCodecs: [kAudioFormatMPEG4AAC],
                isSystemPlayable: true
            )
        ) { error in
            guard case MediaImportValidationError.hdrVideo = error else {
                return XCTFail("Expected HDR rejection, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try MediaImportValidator.validateMediaPolicy(
                videoCodec: .hevc,
                isHDR: false,
                audioCodecs: [kAudioFormatLinearPCM],
                isSystemPlayable: true
            )
        ) { error in
            guard case MediaImportValidationError.unsupportedAudioCodec = error else {
                return XCTFail("Expected audio rejection, got \(error)")
            }
        }
    }

    func testOnlyHEVCMayBypassSystemPlayabilityPreflight() throws {
        XCTAssertNoThrow(
            try MediaImportValidator.validateMediaPolicy(
                videoCodec: .hevc,
                isHDR: false,
                audioCodecs: [kAudioFormatMPEG4AAC],
                isSystemPlayable: false
            )
        )

        XCTAssertThrowsError(
            try MediaImportValidator.validateMediaPolicy(
                videoCodec: .h264,
                isHDR: false,
                audioCodecs: [kAudioFormatMPEG4AAC],
                isSystemPlayable: false
            )
        ) { error in
            guard case MediaImportValidationError.unplayableAsset = error else {
                return XCTFail("Expected H.264 playability rejection, got \(error)")
            }
        }
    }

    func testHEVCProbeStatesDriveCompatibilityConfirmation() {
        let supported = HEVCHardwareProbeResult.supported()
        let unsupported = HEVCHardwareProbeResult.unsupported(
            statusCode: -12906,
            detail: "Hardware session rejected."
        )
        let inconclusive = HEVCHardwareProbeResult.inconclusive(
            statusCode: -12909,
            detail: "No visible frame."
        )

        XCTAssertEqual(supported.status, .supported)
        XCTAssertEqual(unsupported.status, .unsupported)
        XCTAssertEqual(inconclusive.status, .inconclusive)
        XCTAssertFalse(makeInspection(probe: supported).requiresCompatibilityConfirmation)
        XCTAssertTrue(makeInspection(probe: unsupported).requiresCompatibilityConfirmation)
        XCTAssertTrue(makeInspection(probe: inconclusive).requiresCompatibilityConfirmation)
        XCTAssertTrue(makeInspection(probe: supported, width: 8_192, height: 4_096).requiresCompatibilityConfirmation)
        XCTAssertTrue(makeInspection(probe: supported, isSystemPlayable: false).requiresCompatibilityConfirmation)
    }

    @MainActor
    func testPlaylistItemAllowsMissingInspectionMetadataForExistingData() {
        let item = PlaylistItem(
            name: "Existing",
            bookmarkData: Data(),
            sourceDisplayPath: "existing.mp4",
            sourceKind: .local
        )

        XCTAssertNil(item.videoCodec)
        XCTAssertNil(item.mediaSummary)
        XCTAssertNil(item.systemPlayable)
        XCTAssertNil(item.storedHEVCProbeResult)
    }

    private func makeInspection(
        probe: HEVCHardwareProbeResult,
        width: Int = 3_840,
        height: Int = 2_160,
        isSystemPlayable: Bool = true
    ) -> MediaInspection {
        MediaInspection(
            container: "mp4",
            videoCodec: .hevc,
            sampleEntries: ["hvc1"],
            width: width,
            height: height,
            frameRate: 60,
            bitRate: 50_000_000,
            isHDR: false,
            audioCodecs: ["aac "],
            isSystemPlayable: isSystemPlayable,
            hevcHardwareProbe: probe
        )
    }
}

@MainActor
final class BoundedVideoFrameQueueTests: XCTestCase {
    func testQueueSortsFramesAndDropsExpiredFrames() throws {
        let queue = BoundedVideoFrameQueue(capacity: 3)
        queue.configure(
            itemTimeProvider: { CMTime(seconds: 2.5, preferredTimescale: 600) },
            failureHandler: { _ in }
        )
        queue.enqueue(try makeFrame(at: 3))
        queue.enqueue(try makeFrame(at: 1))
        queue.enqueue(try makeFrame(at: 2))

        let selected = try XCTUnwrap(queue.copyFrame(forPresentationHostTime: 0))
        XCTAssertEqual(selected.itemTimeForDisplay.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.droppedFrameCount, 1)
        XCTAssertTrue(queue.hasDeliveredFrame)
    }

    func testQueueRetainsAtMostThreeNewestFrames() throws {
        let queue = BoundedVideoFrameQueue(capacity: 3)
        queue.configure(
            itemTimeProvider: { CMTime(seconds: 4, preferredTimescale: 600) },
            failureHandler: { _ in }
        )
        for timestamp in [4.0, 1.0, 3.0, 2.0] {
            queue.enqueue(try makeFrame(at: timestamp))
        }

        XCTAssertEqual(queue.count, 3)
        let selected = try XCTUnwrap(queue.copyFrame(forPresentationHostTime: 0))
        XCTAssertEqual(selected.itemTimeForDisplay.seconds, 4, accuracy: 0.001)
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.droppedFrameCount, 3)
    }

    func testQueueWaitsWhenOnlyFutureFramesExist() throws {
        let queue = BoundedVideoFrameQueue(capacity: 3)
        queue.configure(
            itemTimeProvider: { CMTime(seconds: 1, preferredTimescale: 600) },
            failureHandler: { _ in }
        )
        queue.enqueue(try makeFrame(at: 2))

        XCTAssertNil(queue.copyFrame(forPresentationHostTime: 0))
        XCTAssertEqual(queue.count, 1)
        XCTAssertFalse(queue.hasDeliveredFrame)
    }

    private func makeFrame(at seconds: Double) throws -> VideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return VideoFrame(
            pixelBuffer: try XCTUnwrap(pixelBuffer),
            itemTimeForDisplay: CMTime(seconds: seconds, preferredTimescale: 600)
        )
    }
}
