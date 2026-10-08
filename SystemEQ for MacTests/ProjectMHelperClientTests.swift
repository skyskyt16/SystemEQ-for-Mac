// Async XCTest entry points avoid the isolated-deinit runtime crash.
// https://github.com/swiftlang/swift/issues/87316
// swiftformat:disable redundantAsync

@testable import SystemEQ_for_Mac
import XCTest

@MainActor
final class ProjectMHelperClientTests: XCTestCase {
    func testStartupCommandsReplayNonDefaultIntent() async {
        XCTAssertEqual(
            ProjectMHelperClient.startupCommands(
                category: "Fractals",
                weight: "Heavy",
                quality: "Low",
                shuffle: false,
                locked: true
            ),
            ["CATEGORY:Fractals", "WEIGHT:Heavy", "QUALITY:Low", "SHUFFLE:0", "LOCK:1"]
        )
    }

    func testStartupCommandsOmitHelperDefaults() async {
        XCTAssertTrue(
            ProjectMHelperClient.startupCommands(
                category: "All",
                weight: "All",
                quality: "High",
                shuffle: true,
                locked: false
            ).isEmpty
        )
    }

    func testReportedSelectionReplacesSynchronizedIntent() async {
        XCTAssertTrue(ProjectMHelperClient.shouldAdoptReportedSelection(selected: "Heavy", current: "Heavy"))
    }

    func testReportedSelectionDoesNotReplacePendingIntent() async {
        XCTAssertFalse(ProjectMHelperClient.shouldAdoptReportedSelection(selected: "Heavy", current: "All"))
    }
}
