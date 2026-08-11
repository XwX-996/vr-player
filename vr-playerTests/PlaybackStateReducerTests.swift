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
