// Synchronous XCTest invocations can crash isolated deinit on older Swift runtimes.
// Keep async entry points: https://github.com/swiftlang/swift/issues/87316
// swiftformat:disable redundantAsync

//
//  DevicePresetManagerTests.swift
//  SystemEQ for MacTests
//
//  Storage roundtrip for the per-output preset map (issue #31)
//

import Combine
@testable import SystemEQ_for_Mac
import XCTest

@MainActor
final class DevicePresetManagerTests: XCTestCase {
    private static let suiteName = "DevicePresetManagerTests"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suite = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        suite.removePersistentDomain(forName: Self.suiteName)
        DevicePresetManager.defaults = suite
        PresetPersistence.defaults = suite
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        DevicePresetManager.defaults = .standard
        PresetPersistence.defaults = .standard
        super.tearDown()
    }

    private func makeRecord(name: String) -> DevicePresetRecord {
        DevicePresetRecord(
            mode: EQBandMode.thirtyOneBand.rawValue,
            appliedGains: [Float](repeating: 1.5, count: 31),
            cleanGains: [Float](repeating: 1.0, count: 31),
            preamp: -3.5,
            bassBoost: 2.0,
            descriptorJSON: "{\"name\":\"\(name)\"}"
        )
    }

    func testRecordApply_roundtripPerDevice() async {
        let manager = DevicePresetManager.shared
        let scarlett = makeRecord(name: "HE400se")
        let speakers = makeRecord(name: "eris")

        manager.recordApply(scarlett, outputUID: "scarlett-uid")
        manager.recordApply(speakers, outputUID: "speakers-uid")

        XCTAssertEqual(manager.record(for: "scarlett-uid"), scarlett)
        XCTAssertEqual(manager.record(for: "speakers-uid"), speakers)
        XCTAssertNil(manager.record(for: "unknown-uid"))
    }

    func testRemovePresetDoesNotRestoreItOnDeviceSwitchOrDeleteOtherDevices() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.set(true, forKey: DevicePresetManager.autoSwitchKey)
        let manager = DevicePresetManager.shared
        manager.recordApply(makeRecord(name: "removed"), outputUID: "removed-uid")
        let other = makeRecord(name: "keep")
        manager.recordApply(other, outputUID: "other-uid")
        manager.removePreset(outputUID: "removed-uid")
        XCTAssertNil(manager.record(for: "removed-uid"))
        XCTAssertEqual(manager.record(for: "other-uid"), other)
        let engine = AudioEngine(defaults: defaults, enableRouting: { _ in true }, disableRouting: { _ in })
        engine.applyEQValues(Array(repeating: 5, count: 10))
        engine.setPreampGain(-4)
        manager.outputChanged(to: "removed-uid", engine: engine)
        XCTAssertEqual(engine.bands.map(\.gain), Array(repeating: 0, count: 10))
        XCTAssertEqual(engine.preampGain, 0)
    }

    func testRecordApply_overwritesSameDevice() async {
        let manager = DevicePresetManager.shared

        manager.recordApply(makeRecord(name: "old"), outputUID: "uid")
        let newer = makeRecord(name: "new")
        manager.recordApply(newer, outputUID: "uid")

        XCTAssertEqual(manager.record(for: "uid"), newer)
    }

    func testSuiteIsolation_standardDefaultsUntouched() async {
        let before = UserDefaults.standard.data(forKey: "devicePresets.v1")

        DevicePresetManager.shared.recordApply(makeRecord(name: "x"), outputUID: "uid")

        XCTAssertEqual(UserDefaults.standard.data(forKey: "devicePresets.v1"), before)
    }

    func testOutputChanged_unmappedDeviceAppliesFlatEQ() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.set(true, forKey: DevicePresetManager.autoSwitchKey)
        defaults.set("{\"name\":\"headphones\"}", forKey: "lastAppliedPresetJSON")
        let engine = AudioEngine(
            defaults: defaults,
            enableRouting: { _ in true },
            disableRouting: { _ in }
        )
        engine.bandMode = .thirtyOneBand
        engine.syncBandsToMode()
        engine.applyEQValues([Float](repeating: 4, count: 31))
        engine.setPreampGain(-6)

        DevicePresetManager.shared.outputChanged(to: "unmapped-uid", engine: engine)

        XCTAssertEqual(engine.bands.map(\.gain), [Float](repeating: 0, count: 31))
        XCTAssertEqual(engine.preampGain, 0)
        XCTAssertNil(defaults.string(forKey: "lastAppliedPresetJSON"))
        let saved = try XCTUnwrap(PresetPersistence.load())
        XCTAssertEqual(saved.mode, .thirtyOneBand)
        XCTAssertEqual(saved.gains, [Float](repeating: 0, count: 31))
        XCTAssertEqual(saved.preamp, 0)
        XCTAssertEqual(saved.bassBoost, 0)
    }

    func testOutputChanged_sameDescriptorStillAppliesDeviceValues() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.set(true, forKey: DevicePresetManager.autoSwitchKey)
        let record = makeRecord(name: "same")
        defaults.set(record.descriptorJSON, forKey: "lastAppliedPresetJSON")
        DevicePresetManager.shared.recordApply(record, outputUID: "mapped-uid")
        let engine = AudioEngine(
            defaults: defaults,
            enableRouting: { _ in true },
            disableRouting: { _ in }
        )
        engine.bandMode = .thirtyOneBand
        engine.syncBandsToMode()
        engine.resetAllBands()

        DevicePresetManager.shared.outputChanged(to: "mapped-uid", engine: engine)

        XCTAssertEqual(engine.bands.map(\.gain), record.appliedGains)
        XCTAssertEqual(engine.preampGain, record.preamp)
    }

    func testOutputChanged_mappedDeviceSwitchesBandModeBeforeApplyingValues() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.set(true, forKey: DevicePresetManager.autoSwitchKey)
        let record = makeRecord(name: "thirty-one-band")
        DevicePresetManager.shared.recordApply(record, outputUID: "mapped-uid")
        let engine = AudioEngine(
            defaults: defaults,
            enableRouting: { _ in true },
            disableRouting: { _ in }
        )
        XCTAssertEqual(engine.bandMode, .tenBand)
        XCTAssertEqual(engine.bands.count, 10)

        DevicePresetManager.shared.outputChanged(to: "mapped-uid", engine: engine)

        XCTAssertEqual(engine.bandMode, .thirtyOneBand)
        XCTAssertEqual(engine.bands.map(\.gain), record.appliedGains)
        XCTAssertEqual(engine.preampGain, record.preamp)
    }

    func testOutputChanged_autoSwitchDisabledLeavesCurrentEQUntouched() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        let engine = AudioEngine(
            defaults: defaults,
            enableRouting: { _ in true },
            disableRouting: { _ in }
        )
        let gains = [Float](repeating: 2, count: 10)
        engine.applyEQValues(gains)

        DevicePresetManager.shared.outputChanged(to: "unmapped-uid", engine: engine)

        XCTAssertEqual(engine.bands.map(\.gain), gains)
    }

    func testOutputChanged_invalidDeviceRecordAppliesFlatEQ() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.set(true, forKey: DevicePresetManager.autoSwitchKey)
        let invalid = DevicePresetRecord(
            mode: EQBandMode.tenBand.rawValue,
            appliedGains: [1, 2],
            cleanGains: [1, 2],
            preamp: -2,
            bassBoost: 0,
            descriptorJSON: "{\"name\":\"invalid\"}"
        )
        DevicePresetManager.shared.recordApply(invalid, outputUID: "invalid-uid")
        let engine = AudioEngine(
            defaults: defaults,
            enableRouting: { _ in true },
            disableRouting: { _ in }
        )
        engine.applyEQValues([Float](repeating: 3, count: 10))

        DevicePresetManager.shared.outputChanged(to: "invalid-uid", engine: engine)

        XCTAssertEqual(engine.bands.map(\.gain), [Float](repeating: 0, count: 10))
        XCTAssertEqual(engine.preampGain, 0)
    }
    func testOutputChangesPublishAfterEngineAndPersistenceIncludingSameDescriptor() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.set(true, forKey: DevicePresetManager.autoSwitchKey)
        let manager = DevicePresetManager.shared
        let first = makeRecord(name: "same")
        let second = DevicePresetRecord(
            mode: EQBandMode.tenBand.rawValue,
            appliedGains: Array(repeating: -2, count: 10),
            cleanGains: Array(repeating: -3, count: 10),
            preamp: -7, bassBoost: 4, descriptorJSON: first.descriptorJSON
        )
        manager.recordApply(first, outputUID: "first")
        manager.recordApply(second, outputUID: "second")
        let engine = AudioEngine(defaults: defaults, enableRouting: { _ in true }, disableRouting: { _ in })
        var received: [DevicePresetRecord?] = []
        let subscription = manager.outputPresetChanges.sink { record in
            received.append(record)
            XCTAssertEqual(
                engine.bands.map(\.gain),
                record?.appliedGains ?? Array(repeating: 0, count: engine.bands.count)
            )
            XCTAssertEqual(engine.preampGain, record?.preamp ?? 0)
            XCTAssertEqual(PresetPersistence.load()?.bassBoost, record?.bassBoost ?? 0)
            XCTAssertEqual(defaults.string(forKey: "lastAppliedPresetJSON"), record?.descriptorJSON)
        }
        defer { subscription.cancel() }

        manager.outputChanged(to: "first", engine: engine)
        manager.outputChanged(to: "second", engine: engine)
        manager.outputChanged(to: "unmapped", engine: engine)
        manager.outputChanged(to: "first", engine: engine)

        XCTAssertEqual(received.count, 4)
        XCTAssertEqual(received[0], first)
        XCTAssertEqual(received[1], second)
        XCTAssertNil(received[2])
        XCTAssertEqual(received[3], first)
    }

    func testDisabledAutoSwitchDoesNotPublishAUIReplacement() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        let manager = DevicePresetManager.shared
        let engine = AudioEngine(defaults: defaults, enableRouting: { _ in true }, disableRouting: { _ in })
        var received = false
        let subscription = manager.outputPresetChanges.sink { _ in received = true }
        defer { subscription.cancel() }

        manager.outputChanged(to: "unmapped", engine: engine)

        XCTAssertFalse(received)
    }
}
