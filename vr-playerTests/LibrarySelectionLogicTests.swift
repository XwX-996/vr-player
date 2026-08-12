import XCTest
@testable import vr_player

final class LibrarySelectionLogicTests: XCTestCase {
    private let folderID = LibraryEntryID.folder(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let videoID = LibraryEntryID.video(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let anotherVideoID = LibraryEntryID.video(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    func testToggleSelectsAndDeselectsOneEntry() {
        let selected = LibrarySelectionLogic.toggling(videoID, in: [])
        XCTAssertEqual(selected, [videoID])

        XCTAssertTrue(LibrarySelectionLogic.toggling(videoID, in: selected).isEmpty)
    }

    func testToggleAllSelectsVisibleFoldersAndVideos() {
        let visible: Set<LibraryEntryID> = [folderID, videoID]

        XCTAssertEqual(LibrarySelectionLogic.togglingAll(visible, in: []), visible)
    }

    func testToggleAllClearsSelectionWhenEveryVisibleEntryIsSelected() {
        let visible: Set<LibraryEntryID> = [folderID, videoID]

        XCTAssertTrue(LibrarySelectionLogic.togglingAll(visible, in: visible).isEmpty)
    }

    func testToggleAllCompletesAPartialSelection() {
        let visible: Set<LibraryEntryID> = [folderID, videoID, anotherVideoID]

        XCTAssertEqual(LibrarySelectionLogic.togglingAll(visible, in: [videoID]), visible)
    }

    func testToggleAllDropsEntriesOutsideTheCurrentDirectory() {
        let visible: Set<LibraryEntryID> = [folderID, videoID]

        XCTAssertEqual(LibrarySelectionLogic.togglingAll(visible, in: [anotherVideoID]), visible)
    }

    func testPruneRemovesEntriesThatAreNoLongerVisible() {
        let visible: Set<LibraryEntryID> = [folderID, videoID]
        let selected: Set<LibraryEntryID> = [folderID, anotherVideoID]

        XCTAssertEqual(LibrarySelectionLogic.pruned(selected, to: visible), [folderID])
    }
}
