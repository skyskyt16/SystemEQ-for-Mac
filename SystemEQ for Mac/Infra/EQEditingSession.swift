import Combine
import Foundation

// MARK: - EQ Editing History and Comparison

/// Session-only history. Each gesture is one edit; A/B slots keep independent histories.
@MainActor
final class EQEditingSession<State: Equatable>: ObservableObject {
    enum Slot: String, CaseIterable { case a = "A", b = "B" }

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var comparisonSlot: Slot?
    private var undoStates: [State] = []
    private var redoStates: [State] = []
    private var pending: State?
    private var comparisonStates: [Slot: State] = [:]
    private var slotHistories: [Slot: (undo: [State], redo: [State])] = [:]
    private let limit = 60

    func begin(_ current: State) {
        if pending == nil { pending = current }
    }

    func finish(_ current: State) {
        guard let before = pending else { return }
        pending = nil
        if before != current {
            undoStates.append(before)
            if undoStates.count > limit { undoStates.removeFirst() }
            redoStates = []
        }
        if let slot = comparisonSlot { comparisonStates[slot] = current }
        publishAvailability()
    }

    func undo(_ current: State) -> State? {
        finish(current)
        guard let previous = undoStates.popLast() else { return nil }
        redoStates.append(current)
        publishAvailability()
        return previous
    }

    func redo(_ current: State) -> State? {
        guard let next = redoStates.popLast() else { return nil }
        undoStates.append(current)
        publishAvailability()
        return next
    }

    func startComparison(_ current: State) {
        finish(current)
        comparisonStates = [.a: current, .b: current]
        slotHistories = [.a: (undoStates, redoStates), .b: ([], [])]
        comparisonSlot = .a
    }

    func select(_ slot: Slot, current: State) -> State? {
        guard let active = comparisonSlot, active != slot else { return nil }
        finish(current)
        comparisonStates[active] = current
        slotHistories[active] = (undoStates, redoStates)
        comparisonSlot = slot
        undoStates = slotHistories[slot]?.undo ?? []
        redoStates = slotHistories[slot]?.redo ?? []
        publishAvailability()
        return comparisonStates[slot]
    }

    func endComparison() {
        comparisonSlot = nil
        comparisonStates = [:]
        slotHistories = [:]
    }

    func reset() {
        pending = nil
        undoStates = []
        redoStates = []
        endComparison()
        publishAvailability()
    }

    private func publishAvailability() {
        canUndo = !undoStates.isEmpty
        canRedo = !redoStates.isEmpty
    }
}
