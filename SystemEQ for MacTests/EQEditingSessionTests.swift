// swiftformat:disable redundantAsync
@testable import SystemEQ_for_Mac
import XCTest

@MainActor
final class EQEditingSessionTests: XCTestCase {
    func testDragIsOneUndoStepAndRedoRestoresFinalValue() async {
        let session = EQEditingSession<Int>()
        session.begin(0)
        session.begin(2)
        session.begin(4)
        session.finish(6)
        XCTAssertEqual(session.undo(6), 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.redo(0), 6)
        XCTAssertFalse(session.canRedo)
    }

    func testNoOpDoesNotReplaceRedoHistory() async {
        let session = EQEditingSession<Int>()
        session.begin(0)
        session.finish(3)
        _ = session.undo(3)
        session.begin(0)
        session.finish(0)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.redo(0), 3)
    }

    func testNewEditAfterUndoDiscardsRedo() async {
        let session = EQEditingSession<Int>()
        session.begin(0)
        session.finish(3)
        _ = session.undo(3)
        session.begin(0)
        session.finish(7)
        XCTAssertNil(session.redo(7))
        XCTAssertEqual(session.undo(7), 0)
    }

    func testComparisonStartsIdenticalThenKeepsIndependentEditsAndHistories() async {
        let session = EQEditingSession<Int>()
        session.startComparison(1)
        XCTAssertEqual(session.comparisonSlot, .a)
        XCTAssertEqual(session.select(.b, current: 1), 1)
        session.begin(1)
        session.finish(8)
        XCTAssertEqual(session.select(.a, current: 8), 1)
        XCTAssertFalse(session.canUndo)
        session.begin(1)
        session.finish(4)
        XCTAssertEqual(session.select(.b, current: 4), 8)
        XCTAssertEqual(session.undo(8), 1)
        XCTAssertEqual(session.redo(1), 8)
        XCTAssertEqual(session.select(.a, current: 8), 4)
        XCTAssertEqual(session.undo(4), 1)
    }

    func testDeviceSwitchDropsPendingEditsHistoryAndComparison() async {
        let session = EQEditingSession<Int>()
        session.startComparison(2)
        session.begin(2)
        session.finish(5)
        session.begin(5)
        session.reset()
        session.finish(9)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
        XCTAssertNil(session.comparisonSlot)
        XCTAssertNil(session.select(.b, current: 9))
    }

    func testEndingComparisonKeepsCurrentSlotsHistory() async {
        let session = EQEditingSession<Int>()
        session.startComparison(2)
        _ = session.select(.b, current: 2)
        session.begin(2)
        session.finish(5)
        session.endComparison()
        XCTAssertNil(session.comparisonSlot)
        XCTAssertEqual(session.undo(5), 2)
    }

    func testHistoryIsBounded() async {
        let session = EQEditingSession<Int>()
        for value in 0..<75 {
            session.begin(value)
            session.finish(value + 1)
        }
        var current = 75
        var count = 0
        while let prior = session.undo(current) {
            current = prior; count += 1
        }
        XCTAssertEqual(count, 60)
        XCTAssertEqual(current, 15)
    }
}
